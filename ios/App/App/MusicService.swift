import Foundation

final class MusicService {
    static let shared = MusicService()

    private let session: URLSession
    private let cache = NSCache<NSString, NSData>()

    init(session: URLSession = .shared) { self.session = session }

    /// Amazon/Deezer provider instances gate their media APIs behind a
    /// Referer/Origin site-check ("Forbidden: requests must come from an allowed
    /// site"). The web client passes it implicitly because the browser stamps
    /// its page origin on every fetch; native URLSession sends neither header
    /// and gets a 403. Stamp the Monochrome origin so native reaches parity.
    private func applyMonochromeOrigin(to request: inout URLRequest) {
        request.setValue("https://monochrome.tf", forHTTPHeaderField: "Origin")
        request.setValue("https://monochrome.tf/", forHTTPHeaderField: "Referer")
    }

    func search(_ query: String) async throws -> SearchResults {
        // The combined `?q=` route is not supported by every HiFi instance. The
        // web client already treats the scoped routes as the compatibility
        // contract, so native search does the same.
        async let trackObject = scopedSearch(path: "/search/?s=\(query.urlQueryEncoded)")
        async let albumObject = scopedSearch(path: "/search/?al=\(query.urlQueryEncoded)")
        async let artistObject = scopedSearch(path: "/search/?a=\(query.urlQueryEncoded)")
        async let playlistObject = scopedSearch(path: "/search/?p=\(query.urlQueryEncoded)")
        let objects = await (trackObject, albumObject, artistObject, playlistObject)
        var results = SearchResults()
        results.tracks = sectionItems(in: objects.0, named: "tracks").compactMap(ModelMapper.track)
        results.albums = sectionItems(in: objects.1, named: "albums").compactMap(ModelMapper.album)
        results.artists = sectionItems(in: objects.2, named: "artists").map { ModelMapper.artist($0) }
        results.playlists = sectionItems(in: objects.3, named: "playlists").compactMap { item in
            guard let id = ModelMapper.string(item, ["id", "uuid"]), let title = ModelMapper.string(item, ["title", "name"]) else { return nil }
            return Playlist(id: id, title: title, description: ModelMapper.string(item, ["description"]), cover: ModelMapper.string(item, ["squareImage", "cover", "image"]), creator: nil, tracks: [])
        }
        guard !results.tracks.isEmpty || !results.albums.isEmpty || !results.artists.isEmpty || !results.playlists.isEmpty else {
            throw ServiceError.unavailable("No search provider returned results. Please try again.")
        }
        return results
    }

    func editorPicks() async throws -> [Album] {
        guard let url = URL(string: "https://monochrome.tf/editors-picks.json") else { throw ServiceError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: data)
        return ModelMapper.array(object, keys: ["albums", "items"]).compactMap(ModelMapper.album)
    }

    func album(id: String, fallback: Album? = nil) async throws -> Album {
        let encodedID = id.urlQueryEncoded
        for path in ["/album/?id=\(encodedID)", "/album/?id=\(encodedID)&offset=0&limit=500"] {
            if let object = try? await json(path: path, cacheable: false), let album = mappedAlbum(from: object) { return album }
        }

        // Curated entries can outlive a provider catalog ID. Resolve the same
        // title/artist to its current ID instead of opening a dead album page.
        if let fallback {
            let object = await scopedSearch(path: "/search/?al=\(fallback.title.urlQueryEncoded)")
            let candidates = sectionItems(in: object, named: "albums").compactMap(ModelMapper.album)
            let match = candidates.first {
                $0.title.caseInsensitiveCompare(fallback.title) == .orderedSame &&
                $0.artist.name.caseInsensitiveCompare(fallback.artist.name) == .orderedSame
            } ?? candidates.first { $0.title.caseInsensitiveCompare(fallback.title) == .orderedSame }
            if let match, match.id != id { return try await album(id: match.id) }
        }
        throw ServiceError.unavailable("This album is no longer available from the configured providers.")
    }

    func recommendations(for trackID: String) async throws -> [Track] {
        let object = try await json(path: "/recommendations/?id=\(trackID.urlQueryEncoded)")
        return ModelMapper.array(object, keys: ["tracks", "items"]).compactMap(ModelMapper.track)
    }

    func lyrics(for track: Track) async -> SyncedLyrics? {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album = track.album?.title, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        components?.queryItems = items

        if let url = components?.url, let lyrics = try? await fetchLRCLIB(url: url) {
            return lyrics
        }

        // Loose search when exact metadata miss (remix titles, featuring tags).
        var search = URLComponents(string: "https://lrclib.net/api/search")
        search?.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
        guard let searchURL = search?.url else { return nil }
        guard let candidates = try? await fetchLRCLIBSearch(url: searchURL) else { return nil }
        return candidates.first
    }

    func resolveStream(for track: Track, quality: PlaybackQuality = .stored) async throws -> StreamResponse {
        // Catalog payloads often include a webpage `url` (e.g. tidal.com/track/…) that
        // was historically mapped into streamURL. Only short-circuit for real media.
        if let url = track.streamURL, Self.isDirectMediaURL(url) {
            return StreamResponse(url: url, provider: track.provider, quality: quality.rawValue, replayGain: nil, peak: nil)
        }

        // Match upstream Monochrome `getStreamUrl` (js/api.js):
        // Amazon Music (Turnstile JWT) → Deezer. TIDAL is catalog-only — never play PREVIEW.
        //
        // Enrichment used to run unconditionally in front of Amazon, but Amazon
        // matches on title/artist/album/duration and never reads the ISRC — only
        // Deezer needs it. Search cards routinely omit the ISRC, so every play
        // paid for an `/info/` fan-out across the whole instance pool (1.2s hedge
        // per host, 12s ceiling) before Amazon was even asked. With the pool
        // currently answering `Upstream API error`, that was a flat multi-second
        // stall in front of the one provider that still works. Fetch only what
        // the leg about to run actually needs.
        var enriched = track.duration > 0 ? track : await enrichTrackMetadata(track)
        var amazonError: Error?
        do {
            return try await resolveAmazonStream(for: enriched, quality: quality)
        } catch {
            amazonError = error
            // Fall through to Deezer like web when Amazon is rate-limited / unavailable.
        }
        // Deezer keys off the ISRC, so pay for the lookup here instead.
        if enriched.isrc?.isEmpty != false {
            enriched = await enrichTrackMetadata(enriched)
        }
        do {
            return try await resolveDeezerStream(for: enriched, quality: quality)
        } catch {
            let amazonDetail = (amazonError as? LocalizedError)?.errorDescription
                ?? amazonError?.localizedDescription
                ?? "Amazon Music unavailable"
            // Report both legs. Reporting only Amazon's made a dead Deezer pool
            // look like an Amazon auth bug.
            let deezerDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if enriched.isrc?.isEmpty == false {
                throw ServiceError.unavailable(
                    "Could not resolve stream URL from Amazon Music or Deezer. Amazon: \(amazonDetail) Deezer: \(deezerDetail)"
                )
            }
            throw ServiceError.unavailable(
                "Could not resolve stream URL: \(amazonDetail). Track has no ISRC for Deezer lookup."
            )
        }
    }

    /// Pull ISRC / duration when search cards omit them. The ISRC is what the
    /// Deezer leg keys on; Amazon only benefits from the duration, so callers
    /// should reach for this lazily rather than in front of every play.
    private func enrichTrackMetadata(_ track: Track) async -> Track {
        if let isrc = track.isrc, !isrc.isEmpty, track.duration > 0 { return track }
        guard let object = try? await json(path: "/info/?id=\(track.playbackID.urlQueryEncoded)", cacheable: true) else {
            return track
        }
        let root = ModelMapper.unwrap(object)
        let items = ModelMapper.array(root, keys: ["items", "data"])
        let matchDict: [String: Any]? = items.first {
            ModelMapper.string($0, ["id"]) == track.playbackID || ModelMapper.string($0, ["id"]) == track.id
        } ?? (root as? [String: Any])
        guard let matchDict, let mapped = ModelMapper.track(matchDict) else { return track }
        var enriched = track
        if enriched.isrc == nil || enriched.isrc?.isEmpty == true { enriched.isrc = mapped.isrc }
        if enriched.duration <= 0 { enriched.duration = mapped.duration }
        if enriched.album == nil { enriched.album = mapped.album }
        return enriched
    }

    private func resolveAmazonStream(for track: Track, quality: PlaybackQuality) async throws -> StreamResponse {
        guard PlaybackSourceSettings.amazonEnabled else {
            throw ServiceError.unavailable("Amazon Music disabled")
        }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            throw ServiceError.unavailable("Amazon lookup needs title and artist")
        }

        let apiBase = PlaybackSourceSettings.amazonApiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bypass = PlaybackSourceSettings.amazonBypassToken.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer bypass token (web settings parity). Otherwise solve Turnstile → JWT.
        var jwt: String?
        if bypass.isEmpty {
            jwt = try await AmazonTurnstileAuth.shared.accessToken(apiBaseURL: apiBase)
        }

        do {
            return try await fetchAmazonTrack(
                title: title,
                artist: artist,
                album: track.album?.title ?? "",
                duration: track.duration,
                quality: quality,
                apiBase: apiBase,
                bypass: bypass,
                jwt: jwt
            )
        } catch let error as URLError where error.code == .timedOut {
            // `/api/track/` searches the Amazon catalog and mints a signed CDN
            // URL before it answers; a cold instance regularly needs longer than
            // one request window. Errors reject in tens of milliseconds, so a
            // timeout means work in progress, not a dead endpoint — give it one
            // more window before handing the track to Deezer.
            //
            // The retry window is shorter than the first: the first request has
            // already warmed the instance, and two full 30s windows back to back
            // put a minute of silence in front of a track that was going to fail
            // anyway.
            do {
                return try await fetchAmazonTrack(
                    title: title,
                    artist: artist,
                    album: track.album?.title ?? "",
                    duration: track.duration,
                    quality: quality,
                    apiBase: apiBase,
                    bypass: bypass,
                    jwt: jwt,
                    timeout: 20
                )
            } catch let retryError as URLError where retryError.code == .timedOut {
                throw ServiceError.unavailable("Amazon track lookup timed out twice at \(apiBase)")
            }
        } catch let error as ServiceError {
            // 401 means the provider rejected the JWT we sent; 428 means it wants
            // one it hasn't seen. Web answers both the same way — re-solve
            // Turnstile and send the fresh JWT *instead of* the bypass token
            // (`forceTurnstile` makes it skip the bypass branch entirely). Native
            // used to skip the retry whenever a bypass token was configured, and
            // to keep sending the rejected token when it wasn't, so a client that
            // hit this once stayed broken for every later track.
            guard case .http(let status) = error, status == 401 || status == 428 else { throw error }
            await AmazonTurnstileAuth.shared.clearCache()
            let fresh = try await AmazonTurnstileAuth.shared.accessToken(apiBaseURL: apiBase, forceRefresh: true)
            return try await fetchAmazonTrack(
                title: title,
                artist: artist,
                album: track.album?.title ?? "",
                duration: track.duration,
                quality: quality,
                apiBase: apiBase,
                bypass: "",
                jwt: fresh
            )
        }
    }

    private func fetchAmazonTrack(
        title: String,
        artist: String,
        album: String,
        duration: Double,
        quality: PlaybackQuality,
        apiBase: String,
        bypass: String,
        jwt: String?,
        timeout: TimeInterval = 30
    ) async throws -> StreamResponse {
        var components = URLComponents(string: apiBase + "/api/track/")
        var items = [
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "album", value: album),
            URLQueryItem(name: "quality", value: quality.amazonQuality),
        ]
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        if !bypass.isEmpty {
            items.append(URLQueryItem(name: "bypass_token", value: bypass))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw ServiceError.invalidResponse }

        // Web can afford 15s because a stalled fetch there costs nothing; here a
        // timeout drops the track to Deezer, whose account pool is frequently
        // dead, so the user sees "no stream" for a request Amazon would have
        // answered a few seconds later.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyMonochromeOrigin(to: &request)
        if let jwt, !jwt.isEmpty {
            request.setValue(jwt, forHTTPHeaderField: "X-Turnstile-JWT")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Amazon states its own failures ("Invalid Turnstile JWT",
            // "turnstile_required"); a bare status code hid which one it was.
            if let detail = Self.providerErrorDetail(in: data), http.statusCode != 401, http.statusCode != 428 {
                throw ServiceError.unavailable("Amazon Music: \(detail)")
            }
            throw ServiceError.http(http.statusCode)
        }
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: data)
        let payload = amazonTrackPayload(object)
        guard let stream = stringValue(payload, ["stream_url", "streamUrl", "url"]),
              let streamURL = URL(string: stream) else {
            throw ServiceError.unavailable("Amazon Music returned no stream URL")
        }

        let key = stringValue(payload, ["decryption_key", "decryptionKey"])
            ?? ((payload["decryption"] as? [String: Any]).flatMap { stringValue($0, ["key"]) })
            ?? ((payload["drm"] as? [String: Any]).flatMap { stringValue($0, ["decryption_key", "decryptionKey"]) })

        let playURL: URL
        if let key, !key.isEmpty {
            // Web routes CENC through SW decryptor; native decrypts to a local clear file.
            playURL = try await AmazonCencDecryptor.decryptFile(
                from: streamURL,
                keyHex: key,
                codec: quality.amazonTargetCodec,
                session: session
            )
        } else {
            playURL = streamURL
        }

        let selected = stringValue(payload, ["quality_selected", "quality"]) ?? quality.amazonQuality
        return StreamResponse(
            url: playURL,
            provider: .amazon,
            quality: selected,
            replayGain: nil,
            peak: nil,
            isPreview: false,
            previewReason: nil,
            mediaDuration: duration > 0 ? duration : nil,
            qualityDetail: Self.amazonQualityDetail(payload, selected: selected)
        )
    }

    /// `24/96`-style detail for the tier Amazon actually served, read off the
    /// `available_qualities` entry that matches `quality_selected` (web's
    /// `getAmazonSelectedQualityInfo`).
    private static func amazonQualityDetail(_ payload: [String: Any], selected: String) -> String? {
        guard let entries = payload["available_qualities"] as? [[String: Any]] else { return nil }
        let match = entries.first { ($0["quality"] as? String) == selected } ?? entries.first
        guard let match,
              let bitDepth = (match["bitDepth"] ?? match["bit_depth"]) as? NSNumber,
              let sampleRate = (match["sampleRate"] ?? match["sample_rate"]) as? NSNumber else { return nil }
        let kHz = sampleRate.doubleValue / 1000
        let rate = kHz == 44.1 ? "44.1" : String(Int(kHz.rounded()))
        return "\(bitDepth.intValue)/\(rate)"
    }

    private func resolveDeezerStream(for track: Track, quality: PlaybackQuality) async throws -> StreamResponse {
        guard PlaybackSourceSettings.deezerEnabled else {
            throw ServiceError.unavailable("Deezer fallback disabled")
        }
        guard let isrc = track.isrc?.trimmingCharacters(in: .whitespacesAndNewlines), !isrc.isEmpty else {
            throw ServiceError.unavailable("Deezer lookup needs ISRC")
        }
        let base = PlaybackSourceSettings.deezerApiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Prefer selected quality, then fall back through lighter formats (FLAC mirrors often 403).
        var formats = [quality.deezerFormat]
        for extra in ["MP3_320", "MP3_128", "FLAC"] where !formats.contains(extra) {
            formats.append(extra)
        }

        var latestError: Error = ServiceError.unavailable("Deezer stream unavailable")
        probeLoop: for format in formats {
            guard var components = URLComponents(string: base + "/stream/") else { continue }
            components.queryItems = [
                URLQueryItem(name: "isrc", value: isrc),
                URLQueryItem(name: "format", value: format),
            ]
            guard let url = components.url else { continue }

            // Web HEAD-checks then feeds URL to <audio>. Accept 405/501 (method not allowed).
            var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            head.httpMethod = "HEAD"
            head.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            applyMonochromeOrigin(to: &head)
            if let (_, headResponse) = try? await session.data(for: head),
               let http = headResponse as? HTTPURLResponse,
               (200..<400).contains(http.statusCode) || http.statusCode == 405 || http.statusCode == 501 {
                return StreamResponse(
                    url: url,
                    provider: .deezer,
                    quality: format,
                    replayGain: nil,
                    peak: nil,
                    isPreview: false,
                    previewReason: nil,
                    mediaDuration: track.duration > 0 ? track.duration : nil
                )
            }

            var probe = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            probe.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            probe.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            applyMonochromeOrigin(to: &probe)
            do {
                let (body, response) = try await session.data(for: probe)
                if let http = response as? HTTPURLResponse {
                    guard (200..<400).contains(http.statusCode) else {
                        let detail = Self.providerErrorDetail(in: body)
                        latestError = detail.map { ServiceError.unavailable($0) } ?? ServiceError.http(http.statusCode)
                        // 503 is the instance reporting that its whole account pool
                        // is dead. Every format draws on that same pool, so probing
                        // the rest just spends eight round trips to relearn it.
                        if http.statusCode == 503 { break probeLoop }
                        continue probeLoop
                    }
                }
                return StreamResponse(
                    url: url,
                    provider: .deezer,
                    quality: format,
                    replayGain: nil,
                    peak: nil,
                    isPreview: false,
                    previewReason: nil,
                    mediaDuration: track.duration > 0 ? track.duration : nil
                )
            } catch {
                latestError = error
            }
        }
        throw latestError
    }

    /// Classic `/track/` asks TIDAL for `assetpresentation=FULL` at the selected quality.
    private func resolveLegacyFullStream(for track: Track, quality: PlaybackQuality) async throws -> StreamResponse {
        let object = try await json(
            path: "/track/?id=\(track.playbackID.urlQueryEncoded)&quality=\(quality.rawValue)",
            streaming: true,
            cacheable: false
        )
        let presentation = (findValue(named: "assetPresentation", in: object) as? String)?.uppercased()
        guard presentation != "PREVIEW" else {
            throw ServiceError.unavailable("Legacy stream is also preview-only.")
        }
        let url: URL
        if let manifest = findValue(named: "manifest", in: object) as? String,
           let extracted = extractURL(fromManifest: manifest) {
            url = extracted
        } else if let urls = findValue(named: "urls", in: object) as? [String],
                  let first = urls.compactMap(URL.init(string:)).first {
            url = first
        } else {
            throw ServiceError.unavailable("Legacy stream missing playable URL.")
        }
        let gain = (findValue(named: "replayGain", in: object) as? NSNumber)?.doubleValue
            ?? (findValue(named: "trackReplayGain", in: object) as? NSNumber)?.doubleValue
        let peak = (findValue(named: "peakAmplitude", in: object) as? NSNumber)?.doubleValue
            ?? (findValue(named: "trackPeakAmplitude", in: object) as? NSNumber)?.doubleValue
        return StreamResponse(
            url: url,
            provider: .tidal,
            quality: quality.rawValue,
            replayGain: gain,
            peak: peak,
            isPreview: false,
            previewReason: nil,
            mediaDuration: track.duration > 0 ? track.duration : nil
        )
    }

    private func resolveTidalManifestStream(for track: Track, quality: PlaybackQuality) async throws -> StreamResponse {
        // Last resort. Prefer AAC-LC for AVPlayer when quality is lossy; still try FLAC
        // formats for lossless settings (joined fMP4). May be PREVIEW-only.
        var query = "id=\(track.playbackID.urlQueryEncoded)&quality=\(quality.rawValue)&adaptive=false"
        quality.tidalFormats.forEach { query += "&formats=\($0)" }
        let object = try await json(path: "/trackManifests/?\(query)", streaming: true, cacheable: false)
        let presentation = (findValue(named: "trackPresentation", in: object) as? String)?.uppercased()
        let previewReason = findValue(named: "previewReason", in: object) as? String
        let isPreview = presentation == "PREVIEW"
        let url: URL
        var mediaDuration: Double?
        if let manifest = findValue(named: "manifest", in: object) as? String,
           let extracted = extractURL(fromManifest: manifest) {
            url = extracted
        } else if let uri = findValue(named: "uri", in: object) as? String,
                  let manifestURL = URL(string: uri) {
            let playable = try await playableURL(from: manifestURL)
            url = playable.url
            mediaDuration = playable.duration
        } else {
            throw ServiceError.unavailable("No playable stream was returned by the configured providers.")
        }
        let gain = (findValue(named: "replayGain", in: object) as? NSNumber)?.doubleValue
        let peak = (findValue(named: "peakAmplitude", in: object) as? NSNumber)?.doubleValue
        return StreamResponse(
            url: url,
            provider: .tidal,
            quality: quality.rawValue,
            replayGain: gain,
            peak: peak,
            isPreview: isPreview,
            previewReason: previewReason,
            mediaDuration: mediaDuration ?? (track.duration > 0 ? track.duration : nil)
        )
    }

    private func amazonTrackPayload(_ object: Any) -> [String: Any] {
        if let dict = object as? [String: Any] {
            if dict["stream_url"] != nil || dict["streamUrl"] != nil { return dict }
            for key in ["data", "track", "result"] {
                if let nested = dict[key] as? [String: Any],
                   nested["stream_url"] != nil || nested["streamUrl"] != nil {
                    return nested
                }
            }
            return dict
        }
        return [:]
    }

    /// Both providers answer failures with a JSON body that says what actually
    /// went wrong ("All Deezer accounts are dead", "Invalid Turnstile JWT").
    /// A bare status code hides that, so surface their wording when present.
    private static func providerErrorDetail(in body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        for key in ["error", "message", "detail"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func stringValue(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func isDirectMediaURL(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        let ext = url.pathExtension.lowercased()
        return ["m4a", "mp3", "aac", "flac", "ogg", "wav", "mp4", "m3u8", "mpd"].contains(ext)
    }

    /// How long a given instance gets to prove itself before the next one is also
    /// allowed into the race. Healthy instances answer well inside this, so the
    /// common case still costs exactly one request.
    private static let instanceHedgeDelay: Double = 1.2

    /// The instance pool is wildly uneven: some hosts answer in a few hundred
    /// milliseconds, others are cold and hold the connection open until the timeout.
    /// Walking them strictly in order meant one dead leader cost a full 12s before
    /// the second was even attempted — with several dead, the wait in front of a
    /// track ran into minutes. Hedge instead: stagger the fan-out and take the first
    /// instance that returns usable JSON, cancelling the rest.
    private func json(path: String, streaming: Bool = false, cacheable: Bool = true) async throws -> Any {
        let cacheKey = path as NSString
        if cacheable, let data = cache.object(forKey: cacheKey) { return try JSONSerialization.jsonObject(with: data as Data) }
        let bases = await InstanceDirectory.shared.bases(streaming: streaming)
        let timeout: TimeInterval = streaming ? 8 : 12
        let hedgeDelay = Self.instanceHedgeDelay
        let session = self.session

        let winner = await withTaskGroup(of: Data?.self) { group -> Data? in
            var launched = 0
            for base in bases {
                guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { continue }
                let headStart = Double(launched) * hedgeDelay
                launched += 1
                group.addTask {
                    if headStart > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(headStart * 1_000_000_000))
                    }
                    guard !Task.isCancelled else { return nil }
                    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    guard let fetched = try? await session.data(for: request),
                          let http = fetched.1 as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          (try? JSONSerialization.jsonObject(with: fetched.0)) != nil else { return nil }
                    return fetched.0
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        guard let data = winner else {
            throw ServiceError.unavailable("No configured instance answered \(path).")
        }
        if cacheable { cache.setObject(data as NSData, forKey: cacheKey) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func scopedSearch(path: String) async -> Any? { try? await json(path: path, cacheable: false) }

    private func sectionItems(in object: Any?, named section: String) -> [[String: Any]] {
        guard let object else { return [] }
        let root = (object as? [String: Any])?["data"] ?? object
        if let dict = root as? [String: Any] {
            if let value = dict[section] { return itemArray(value) }
            if dict["items"] != nil { return itemArray(dict) }
            for value in dict.values {
                let nested = sectionItems(in: value, named: section)
                if !nested.isEmpty { return nested }
            }
        }
        return itemArray(root)
    }

    private func itemArray(_ value: Any) -> [[String: Any]] {
        let unwrapped = (value as? [String: Any])?["items"] ?? value
        guard let values = unwrapped as? [Any] else { return [] }
        return values.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            return (dict["item"] ?? dict["track"] ?? dict["value"]) as? [String: Any] ?? dict
        }
    }

    private func mappedAlbum(from object: Any) -> Album? {
        let root = (object as? [String: Any])?["data"] ?? object
        guard let dict = root as? [String: Any], var album = ModelMapper.album(dict) else { return nil }
        let tracks = itemArray(dict).compactMap(ModelMapper.track)
        if !tracks.isEmpty { album.tracks = tracks }
        return album
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
    }

    private func findValue(named key: String, in value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if let found = dict[key] { return found }
            for nested in dict.values { if let found = findValue(named: key, in: nested) { return found } }
        } else if let array = value as? [Any] {
            for nested in array { if let found = findValue(named: key, in: nested) { return found } }
        }
        return nil
    }

    private func extractURL(fromManifest manifest: String) -> URL? {
        let decodedData = Data(base64Encoded: manifest, options: .ignoreUnknownCharacters)
        let decoded = decodedData.flatMap { String(data: $0, encoding: .utf8) } ?? manifest
        if let data = decoded.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urls = json["urls"] as? [String] {
            return urls.compactMap(URL.init(string:)).first
        }
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\\\"'<>]+"),
              let match = regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
              let range = Range(match.range, in: decoded) else { return nil }
        return URL(string: String(decoded[range]))
    }

    /// AVPlayer doesn't accept MPEG-DASH directly. HiFi's fixed manifests are
    /// static fragmented-MP4 timelines, so join the initialization fragment and
    /// media fragments into one local fragmented MP4 that AVFoundation can open
    /// without waiting on a synthetic local HLS playlist.
    private func playableURL(from manifestURL: URL) async throws -> (url: URL, duration: Double?) {
        let (data, response) = try await session.data(from: manifestURL)
        try validate(response)
        guard let xml = String(data: data, encoding: .utf8) else { throw ServiceError.malformed("stream manifest") }
        if xml.contains("#EXTM3U") { return (manifestURL, nil) }
        guard let initialization = attribute("initialization", in: xml),
              let media = attribute("media", in: xml),
              attribute("timescale", in: xml) != nil else {
            throw ServiceError.malformed("DASH audio timeline")
        }
        let mediaDuration = attribute("mediaPresentationDuration", in: xml).flatMap(Self.parseISO8601Duration)
        let startNumber = Int(attribute("startNumber", in: xml) ?? "1") ?? 1
        let segmentPattern = #"<S\s+([^>]+)/?>"#
        let regex = try NSRegularExpression(pattern: segmentPattern)
        let nsRange = NSRange(xml.startIndex..., in: xml)
        var segmentCount = 0
        for match in regex.matches(in: xml, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let attributes = String(xml[range])
            guard attribute("d", in: attributes) != nil else { continue }
            let repeats = max(0, Int(attribute("r", in: attributes) ?? "0") ?? 0)
            segmentCount += repeats + 1
        }
        guard segmentCount > 0 else { throw ServiceError.malformed("DASH segment timeline") }
        guard let initURL = URL(string: xmlDecoded(initialization), relativeTo: manifestURL)?.absoluteURL else {
            throw ServiceError.malformed("DASH initialization URL")
        }
        let mediaTemplate = xmlDecoded(media)
        var combined = try await fragmentData(from: initURL)
        for offset in 0..<segmentCount {
            let segment = mediaTemplate.replacingOccurrences(of: "$Number$", with: String(startNumber + offset))
            guard let segmentURL = URL(string: segment, relativeTo: manifestURL)?.absoluteURL else {
                throw ServiceError.malformed("DASH media URL")
            }
            combined.append(try await fragmentData(from: segmentURL))
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("monochrome-\(UUID().uuidString).m4a")
        try combined.write(to: target, options: .atomic)
        return (target, mediaDuration)
    }

    /// Parses MPD durations like `PT29.976S`, `PT7M36S`, `PT1H2M3.5S`.
    private static func parseISO8601Duration(_ value: String) -> Double? {
        guard value.hasPrefix("PT") else { return nil }
        var seconds = 0.0
        var number = ""
        for character in value.dropFirst(2) {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch character {
            case "H": seconds += amount * 3600
            case "M": seconds += amount * 60
            case "S": seconds += amount
            default: return nil
            }
        }
        return seconds > 0 ? seconds : nil
    }

    private func fragmentData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("audio/mp4", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard !data.isEmpty else { throw ServiceError.malformed("empty audio fragment") }
        return data
    }

    private func attribute(_ name: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))=['\\\"]([^'\\\"]+)['\\\"]"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func xmlDecoded(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func fetchLRCLIB(url: URL) async throws -> SyncedLyrics? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseLRCLIBObject(object)
    }

    private func fetchLRCLIBSearch(url: URL) async throws -> [SyncedLyrics] {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap(parseLRCLIBObject).filter { !$0.isEmpty }
    }

    private func parseLRCLIBObject(_ object: [String: Any]) -> SyncedLyrics? {
        let synced = object["syncedLyrics"] as? String
        let plain = object["plainLyrics"] as? String
        let lines = Self.parseLRC(synced ?? "")
        guard !lines.isEmpty || !(plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            return nil
        }
        return SyncedLyrics(lines: lines, plainText: plain, provider: "LRCLIB")
    }

    static func parseLRC(_ subtitles: String) -> [LyricLine] {
        let pattern = #"\[(\d+):(\d+)(?:\.(\d+))?\]\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var lines: [LyricLine] = []
        for raw in subtitles.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let minRange = Range(match.range(at: 1), in: line),
                  let secRange = Range(match.range(at: 2), in: line),
                  let textRange = Range(match.range(at: 4), in: line) else { continue }
            let minutes = Double(line[minRange]) ?? 0
            let seconds = Double(line[secRange]) ?? 0
            var fraction = 0.0
            if match.range(at: 3).location != NSNotFound, let fracRange = Range(match.range(at: 3), in: line) {
                let digits = String(line[fracRange])
                let value = Double(digits) ?? 0
                fraction = value / pow(10, Double(digits.count))
            }
            let text = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(LyricLine(id: lines.count, time: minutes * 60 + seconds + fraction, text: text))
        }
        return lines
    }
}

private extension String {
    var urlQueryEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self }
}

/// The instance pool rotates far faster than the app ships. Web reads
/// `monochrome.tf/instances.json` on every load; native pinned a build-time copy
/// and had already drifted from it (`hifi.p1nkhamster.com` where the document
/// says `.xyz`, no `katze.qqdl.site`, no `tidal.kinoplus.online`), so native was
/// racing hosts the project had already rotated out. Read the same document,
/// persist the last good answer, and keep the compiled list only as a seed for
/// the very first launch.
actor InstanceDirectory {
    static let shared = InstanceDirectory()

    /// Only used until the first successful fetch, or if the document is
    /// unreachable on a device that has never fetched it.
    private static let seedAPI = [
        "https://eu-central.monochrome.tf", "https://us-west.monochrome.tf",
        "https://arran.monochrome.tf", "https://api.monochrome.tf",
        "https://monochrome-api.samidy.com", "https://triton.squid.wtf",
        "https://wolf.qqdl.site", "https://maus.qqdl.site", "https://vogel.qqdl.site",
        "https://hund.qqdl.site", "https://tidal.kinoplus.online",
    ]
    private static let seedStreaming = [
        "https://arran.monochrome.tf", "https://triton.squid.wtf", "https://wolf.qqdl.site",
        "https://maus.qqdl.site", "https://vogel.qqdl.site", "https://katze.qqdl.site",
        "https://hund.qqdl.site", "https://hifi.p1nkhamster.xyz",
    ]

    /// The official mirrors all serve the same document; the primary going down
    /// is exactly when a fresh list matters most.
    private static let documentURLs = [
        "https://monochrome.tf/instances.json",
        "https://lossless.wtf/instances.json",
        "https://monochrome.samidy.com/instances.json",
    ]

    private static let apiKey = "native.instances.api"
    private static let streamingKey = "native.instances.streaming"
    private static let fetchedAtKey = "native.instances.fetchedAt"
    private static let ttl: TimeInterval = 6 * 3600

    private var api: [String]
    private var streaming: [String]
    private var fetchedAt: Date
    private var refreshTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let storedAPI = Self.normalize(defaults.stringArray(forKey: Self.apiKey) ?? [])
        let storedStreaming = Self.normalize(defaults.stringArray(forKey: Self.streamingKey) ?? [])
        api = storedAPI.isEmpty ? Self.seedAPI : storedAPI
        streaming = storedStreaming.isEmpty ? Self.seedStreaming : storedStreaming
        let stamp = defaults.double(forKey: Self.fetchedAtKey)
        fetchedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : .distantPast
    }

    /// Never waits on the network. Answers from the persisted (or seeded) pool
    /// and refreshes behind the caller, so wiring this in cannot add latency to
    /// the request the user is actually waiting on.
    func bases(streaming wantStreaming: Bool) -> [String] {
        refreshIfStale()
        return wantStreaming ? streaming : api
    }

    /// Call at launch so the first search already runs against a current pool.
    func refreshIfStale() {
        guard refreshTask == nil, Date().timeIntervalSince(fetchedAt) > Self.ttl else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            await self?.clearRefreshTask()
        }
    }

    private func clearRefreshTask() { refreshTask = nil }

    private func refresh() async {
        for candidate in Self.documentURLs {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let fetched = try? await URLSession.shared.data(for: request),
                  let http = fetched.1 as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = (try? JSONSerialization.jsonObject(with: fetched.0)) as? [String: Any]
            else { continue }

            let freshAPI = Self.normalize(object["api"] as? [String] ?? [])
            let freshStreaming = Self.normalize(object["streaming"] as? [String] ?? [])
            // A mirror that answers with an empty or malformed list must not be
            // allowed to erase a working pool.
            guard !freshAPI.isEmpty || !freshStreaming.isEmpty else { continue }

            if !freshAPI.isEmpty {
                api = freshAPI
                UserDefaults.standard.set(freshAPI, forKey: Self.apiKey)
            }
            if !freshStreaming.isEmpty {
                streaming = freshStreaming
                UserDefaults.standard.set(freshStreaming, forKey: Self.streamingKey)
            }
            fetchedAt = Date()
            UserDefaults.standard.set(fetchedAt.timeIntervalSince1970, forKey: Self.fetchedAtKey)
            return
        }
    }

    /// The document ships trailing slashes on some entries (`api.monochrome.tf/`,
    /// `hifi.p1nkhamster.xyz/`) and `json(path:)` concatenates paths directly.
    /// Internal rather than private so the parsing contract can be tested without
    /// standing up a network fetch.
    static func normalize(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false,
                  seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
