import Foundation

final class MusicService {
    static let shared = MusicService()

    /// Provider gateways deliberately allow the official web app rather than arbitrary API clients.
    /// Preserve that contract when the native shell makes the equivalent request.
    static let webRequestHeaders = [
        "Origin": "https://monochrome.tf",
        "Referer": "https://monochrome.tf/",
    ]

    private let session: URLSession
    private let cache = NSCache<NSString, NSData>()

    init(session: URLSession = .shared) { self.session = session }

    /// Amazon/Deezer provider instances gate their media APIs behind a
    /// Referer/Origin site-check ("Forbidden: requests must come from an allowed
    /// site"). The web client passes it implicitly because the browser stamps
    /// its page origin on every fetch; native URLSession sends neither header
    /// and gets a 403. Stamp the Monochrome origin so native reaches parity.
    private func applyMonochromeOrigin(to request: inout URLRequest) {
        Self.webRequestHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
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

    func editorPicks() async throws -> [EditorPick] {
        guard let url = URL(string: "https://monochrome.tf/editors-picks.json") else { throw ServiceError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: data)
        // The feed mixes "album" and "track" entries; matching on `type` keeps
        // songs from being coerced into degenerate zero-track albums whose id
        // then 404s when opened as an album page.
        return ModelMapper.array(object, keys: ["albums", "items"]).compactMap { item in
            let type = ModelMapper.string(item, ["type"])?.lowercased()
            if type == "track" || type == "song" {
                return ModelMapper.track(item).map(EditorPick.track)
            }
            return ModelMapper.album(item).map(EditorPick.album)
        }
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

    /// Full track object from `/info`, the only route that carries `bpm`, `key`
    /// and `keyScale`. Cached, because those values never change.
    func trackInfo(id: String) async throws -> Track {
        let object = try await json(path: "/info/?id=\(id.urlQueryEncoded)")
        let root = (object as? [String: Any])?["data"] ?? object
        let candidates = ModelMapper.array(root, keys: ["items", "tracks"])
        if let dict = root as? [String: Any], let track = ModelMapper.track(dict) { return track }
        if let track = candidates.compactMap(ModelMapper.track).first { return track }
        throw ServiceError.invalidResponse
    }

    func similarArtists(for artistID: String) async throws -> [Artist] {
        let object = try await json(path: "/artist/similar/?id=\(artistID.urlQueryEncoded)")
        return ModelMapper.array(object, keys: ["artists", "items"]).map { ModelMapper.artist($0) }
    }

    func artistTopTracks(for artistID: String, limit: Int = 10) async throws -> [Track] {
        let object = try await json(path: "/artist/?f=\(artistID.urlQueryEncoded)&skip_tracks=true&offset=0&limit=\(limit)")
        return ModelMapper.array(object, keys: ["topTracks", "tracks", "items"]).compactMap(ModelMapper.track)
    }

    /// Best-effort resolution of a Last.fm artist/title pair to a catalog track.
    func searchTrack(artist: String, title: String) async -> [Track] {
        let object = await scopedSearch(path: "/search/?s=\("\(artist) \(title)".urlQueryEncoded)")
        return sectionItems(in: object, named: "tracks").compactMap(ModelMapper.track)
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

    /// `intent` is passed straight to Unified Playback: web asks for `download`
    /// when it is saving a file rather than playing one, and the API can serve a
    /// different resource for each.
    func resolveStream(
        for track: Track,
        quality: PlaybackQuality = .stored,
        skipping skipped: Set<Provider> = [],
        intent: String = "stream"
    ) async throws -> StreamResponse {
        // Podcasts play the enclosure URL directly — never run music providers.
        // Quality token comes from the enclosure MIME/extension (MP3/AAC/…), not
        // the user's streaming preference — badge must match what actually plays.
        if track.isPodcast, let url = track.streamURL {
            let token = track.audioQuality
                ?? PlaybackQuality.enclosureToken(mimeType: track.enclosureType, url: url)
            return StreamResponse(url: url, provider: .podcast, quality: token, replayGain: nil, peak: nil,
                                  mediaDuration: track.duration > 0 ? track.duration : nil)
        }
        // Catalog payloads often include a webpage `url` (e.g. tidal.com/track/…) that
        // was historically mapped into streamURL. Only short-circuit for real media.
        // Stamp format from the URL/catalog — never the requested preference tier.
        if let url = track.streamURL,
           Self.isDirectMediaURL(url),
           !skipped.contains(track.provider) {
            let token = track.audioQuality
                ?? PlaybackQuality.mediaFormatToken(mimeType: track.enclosureType, url: url)
                ?? track.catalogQuality?.rawValue
                ?? "UNKNOWN"
            return StreamResponse(url: url, provider: track.provider, quality: token, replayGain: nil, peak: nil)
        }

        // Unified Playback (`music-api.geeked.wtf`) first, then Deezer — the
        // chain web `getStreamUrl` now runs. The three legs that used to sit in
        // front of Deezer (Rythm, the direct Amazon API, Qobuz-via-Lucida) are
        // gone: Unified Playback resolves Monochrome, Amazon and TIDAL itself,
        // and web migrates clients off the old Rythm/Amazon hosts outright.
        // TIDAL stays catalog-only.
        //
        // `skipping` lets PlaybackEngine drop a provider that already handed us
        // a URL AVPlayer rejected (signed CDN expire, CENC decode fail) and
        // continue down the chain. Unified Playback can answer as Amazon, TIDAL
        // or Monochrome, so it is skipped only once every source it can select
        // has been exhausted.
        var enriched = track
        let unifiedSources: Set<Provider> = [.amazon, .tidal, .monochrome]
        var unifiedError: Error?
        if !unifiedSources.isSubset(of: skipped) {
            do {
                return try await resolveUnifiedStream(
                    for: enriched, quality: quality, skipping: skipped, intent: intent
                )
            } catch {
                unifiedError = error
            }
        }

        // Deezer keys off the ISRC, so pay for the metadata lookup only once the
        // leg that needs it is actually going to run. Search cards routinely omit
        // the ISRC, and `/info/` fans out across the whole instance pool.
        if enriched.isrc?.isEmpty != false {
            enriched = await enrichTrackMetadata(enriched)
        }
        let unifiedDetail = Self.legDetail(
            unifiedError,
            fallback: unifiedSources.isSubset(of: skipped)
                ? "Unified Playback skipped"
                : (PlaybackSourceSettings.unifiedEnabled ? "Unified Playback unavailable" : "Unified Playback disabled")
        )
        if !skipped.contains(.deezer) {
            do {
                return try await resolveDeezerStream(for: enriched, quality: quality)
            } catch {
                let deezerDetail = Self.legDetail(error, fallback: "Deezer unavailable")
                throw ServiceError.unavailable(
                    "Could not resolve stream URL from Unified Playback or Deezer. Unified Playback: \(unifiedDetail) Deezer: \(deezerDetail)"
                )
            }
        }
        throw ServiceError.unavailable(
            "Could not resolve stream URL. Unified Playback: \(unifiedDetail)"
        )
    }

    /// Unified Playback with the transient-failure retry the old Amazon leg had:
    /// the API searches the catalog and mints a signed CDN URL before it answers,
    /// so a cold instance regularly needs more than one request window, and a
    /// timeout there means work in progress rather than a dead endpoint.
    ///
    /// A source PlaybackEngine has already exhausted is not worth resolving to
    /// again, so a response naming one is rejected and the track drops to Deezer.
    private func resolveUnifiedStream(
        for track: Track,
        quality: PlaybackQuality,
        skipping skipped: Set<Provider>,
        intent: String
    ) async throws -> StreamResponse {
        var lastError: Error = ServiceError.unavailable("Unified Playback unavailable")
        for attempt in 0..<3 {
            do {
                let response = try await UnifiedPlaybackService.resolveStream(
                    for: track, quality: quality, intent: intent, session: session
                )
                guard !skipped.contains(response.provider) else {
                    throw ServiceError.unavailable(
                        "Unified Playback resolved to \(response.provider.title), which already failed for this track"
                    )
                }
                return response
            } catch {
                lastError = error
                guard Self.isTransientPlaybackError(error), attempt < 2 else { throw error }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(500 + attempt * 900) * 1_000_000)
            }
        }
        throw lastError
    }

    /// Provider errors are surfaced verbatim so the message names which leg gave
    /// up and why, rather than a single "no stream" for four different causes.
    private static func legDetail(_ error: Error?, fallback: String) -> String {
        guard let error else { return fallback }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Pull ISRC / duration when search cards omit them. The ISRC is what the
    /// Deezer leg keys on; Unified Playback matches on title/artist and only
    /// narrows with them, so callers reach for this lazily rather than in front
    /// of every play.
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

    static func isTransientPlaybackError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(urlError.code)
        }
        if let serviceError = error as? ServiceError, case .http(let status) = serviceError {
            return status == 403 || status == 404 || status == 408 || status == 409
                || status == 425 || status == 429 || status >= 500
        }
        return false
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

            // A single Range GET is enough to validate the URL: the CDN answers
            // 200/206 for a playable file and a 4xx/5xx/error body otherwise.
            // The old HEAD pre-check doubled every format's latency (HEAD then GET)
            // for no extra signal — on a dead pool that meant up to eight round
            // trips of ~12s each before the leg gave up. Accept 405/501 here too:
            // some CDN mirrors reject the Range method but still serve the file.
            var probe = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            probe.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            probe.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            applyMonochromeOrigin(to: &probe)
            do {
                let (body, response) = try await session.data(for: probe)
                if let http = response as? HTTPURLResponse {
                    let ok = (200..<400).contains(http.statusCode)
                        || http.statusCode == 405 || http.statusCode == 501
                    guard ok else {
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
                    requestHeaders: Self.webRequestHeaders,
                    isPreview: false,
                    previewReason: nil,
                    mediaDuration: track.duration > 0 ? track.duration : nil
                )
            } catch let error as URLError where error.code == .timedOut || error.code == .cannotConnectToHost || error.code == .cannotFindHost || error.code == .networkConnectionLost {
                // Host unreachable, not this format's fault. Every format targets
                // the same instance, so retrying the rest just stacks another
                // ~12s timeout each — the "infinite loading" tail. Give up the
                // whole leg now and let the caller surface the failure fast.
                latestError = error
                break probeLoop
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

    private static func providerErrorDetail(in body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        for key in ["error", "message", "detail"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
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

    /// Web (monochrome.tf) renders LRC timestamps with no trailing text as "…"
    /// instead of dropping them, since they mark instrumental/non-vocal gaps
    /// the sync should still land on. `(.*)`  keeps the match on those lines.
    static func parseLRC(_ subtitles: String) -> [LyricLine] {
        let pattern = #"\[(\d+):(\d+)(?:\.(\d+))?\]\s*(.*)"#
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
            let rawText = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = rawText.isEmpty ? "..." : rawText
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
