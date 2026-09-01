import Foundation

/// Unified Playback resolver (`music-api.geeked.wtf`, envelope schema v1/v2).
///
/// This is the single playback leg the web client now runs: it aggregates
/// Monochrome, Amazon and TIDAL server-side and answers with an envelope of
/// already-resolved playback resources. It replaces the three legs native used
/// to walk in front of Deezer — Rythm (`track-api.monochrome.tf`), the direct
/// Amazon API (`amz.geeked.wtf`) and Qobuz-via-Lucida. Web dropped all three:
/// the first two are listed as legacy base URLs it actively migrates clients
/// off, and Lucida is gone from the bundle entirely.
///
/// Matching is on title + artist, with album, ISRC and duration narrowing it, so
/// no catalog ID is needed. Requests carry the client API token as a bearer; a
/// client on the shared default token must also present a Turnstile JWT in
/// `X-Turnstile-JWT`, minted by exchanging a Cloudflare solve at
/// `/api/auth/turnstile`.
enum UnifiedPlaybackService {
    /// Where the `X-Turnstile-JWT` comes from. Production solves Turnstile in a
    /// WKWebView, which needs a foreground window and a real Cloudflare round
    /// trip — neither exists in a test bundle, so the seam lets the session
    /// handling (first solve, 401/428 re-solve, single retry) be exercised
    /// directly.
    static var sessionTokenProvider: (_ base: String, _ forceRefresh: Bool) async throws -> String = {
        base, forceRefresh in
        try await AmazonTurnstileAuth.shared.accessToken(
            apiBaseURL: base,
            exchange: .unified,
            siteKey: PlaybackSourceSettings.unifiedTurnstileSiteKey,
            action: PlaybackSourceSettings.unifiedTurnstileAction,
            forceRefresh: forceRefresh
        )
    }

    /// A 429 takes the whole leg out for a while rather than for one track: the
    /// limit is per client, so retrying on the next track only spends another
    /// request to relearn it. Mirrors web `setUnifiedPlaybackRateLimited`.
    private static let rateLimitKey = "native.unifiedRateLimitedUntil"
    private static let defaultRateLimitSeconds: TimeInterval = 1800

    static var isRateLimited: Bool {
        Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: rateLimitKey)
    }

    static func clearRateLimit() {
        UserDefaults.standard.removeObject(forKey: rateLimitKey)
    }

    private static func setRateLimited(from response: HTTPURLResponse) {
        let retryAfter = (response.value(forHTTPHeaderField: "Retry-After") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Double(retryAfter) ?? 0
        let until = Date().timeIntervalSince1970 + (seconds > 0 ? seconds : defaultRateLimitSeconds)
        UserDefaults.standard.set(until, forKey: rateLimitKey)
    }

    static func resolveStream(
        for track: Track,
        quality: PlaybackQuality,
        intent: String = "stream",
        session: URLSession = .shared
    ) async throws -> StreamResponse {
        guard PlaybackSourceSettings.unifiedEnabled else {
            throw ServiceError.unavailable("Unified Playback disabled")
        }
        guard !isRateLimited else {
            throw ServiceError.unavailable("Unified Playback is rate limiting this client")
        }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw ServiceError.unavailable("Unified Playback lookup needs a track title")
        }
        let apiToken = PlaybackSourceSettings.unifiedApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiToken.isEmpty else {
            throw ServiceError.unavailable("Unified Playback needs an API token")
        }

        let base = PlaybackSourceSettings.unifiedApiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sharedToken = apiToken == PlaybackSourceSettings.defaultUnifiedApiToken

        var lastError: Error = ServiceError.unavailable("Unified Playback unavailable")
        for attempt in 0..<2 {
            // The shared default token is only accepted alongside a Turnstile
            // JWT, so solve up front for it. A client with its own token sends
            // whatever JWT is already cached and solves only once the API asks
            // for one (401/428) — exactly what web does.
            let jwt: String?
            if sharedToken || attempt > 0 {
                jwt = try await sessionTokenProvider(base, attempt > 0)
            } else {
                jwt = await AmazonTurnstileAuth.shared.cachedJWT(for: .unified)
            }

            do {
                let envelope = try await fetchEnvelope(
                    track: track, title: title, quality: quality, intent: intent,
                    base: base, apiToken: apiToken, jwt: jwt, session: session
                )
                return try await streamResponse(from: envelope, track: track, quality: quality, session: session)
            } catch let failure as LookupFailure {
                lastError = failure.service
                // 401 means the JWT we sent was rejected, 428 that the API wants
                // one it has not seen. Both are answered the same way: drop the
                // cached session and re-solve, once.
                guard failure.status == 401 || failure.status == 428, attempt == 0 else { throw failure.service }
                await AmazonTurnstileAuth.shared.clearCache(for: .unified)
            }
        }
        throw lastError
    }

    /// Carries the status alongside the message so `resolveStream` can branch on
    /// it — the re-solve is for 401/428 only — while the chain error still
    /// reports the upstream detail verbatim.
    private struct LookupFailure: Error {
        let status: Int
        let service: ServiceError
    }

    static func lookupQueryItems(
        track: Track,
        title: String,
        quality: PlaybackQuality,
        intent: String
    ) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "track", value: title)]
        let artist = track.artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist", value: artist)) }
        let album = (track.album?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !album.isEmpty { items.append(URLQueryItem(name: "album", value: album)) }
        let isrc = (track.isrc ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !isrc.isEmpty { items.append(URLQueryItem(name: "isrc", value: isrc)) }
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        items.append(URLQueryItem(name: "intent", value: intent))
        items.append(URLQueryItem(name: "quality", value: quality.rawValue))
        return items
    }

    private static func fetchEnvelope(
        track: Track,
        title: String,
        quality: PlaybackQuality,
        intent: String,
        base: String,
        apiToken: String,
        jwt: String?,
        session: URLSession,
        timeout: TimeInterval = 20
    ) async throws -> [String: Any] {
        var components = URLComponents(string: base + "/api/v2/track/")
        components?.queryItems = lookupQueryItems(track: track, title: title, quality: quality, intent: intent)
        guard let url = components?.url else { throw ServiceError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        if let jwt, !jwt.isEmpty { request.setValue(jwt, forHTTPHeaderField: "X-Turnstile-JWT") }
        MusicService.webRequestHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ServiceError.unavailable("Unified Playback lookup timed out at \(base)")
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }

        if http.statusCode == 429 {
            setRateLimited(from: http)
            throw ServiceError.unavailable("Unified Playback is rate limiting this client")
        }
        // 404/502 are the API saying it could not resolve the recording, not a
        // transport failure — the caller drops straight to Deezer.
        if http.statusCode == 404 || http.statusCode == 502 {
            throw ServiceError.unavailable("Unified Playback found no playable source")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 428 {
                throw LookupFailure(status: http.statusCode, service: .http(http.statusCode))
            }
            // Keep retryable statuses structured. Folding a 503 into a
            // message-only `.unavailable` made the caller's retry layer treat
            // the most common intermittent gateway failure as permanent.
            if http.statusCode == 408 || http.statusCode == 409 || http.statusCode == 425
                || http.statusCode >= 500 {
                throw ServiceError.http(http.statusCode)
            }
            if let detail = AmazonTurnstileAuth.exchangeErrorDetail(in: data) {
                throw ServiceError.unavailable("Unified Playback: \(detail)")
            }
            throw ServiceError.http(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidResponse
        }
        // The envelope is versioned, and a major bump can move any field this
        // resolver reads. Refusing an unknown version fails over to Deezer
        // instead of playing whatever a mis-parsed payload happens to yield.
        let version = String(describing: object["schema_version"] ?? "")
        let major = version.split(separator: ".").first.map(String.init) ?? ""
        guard major == "1" || major == "2" else {
            throw ServiceError.unavailable(
                "Unsupported Unified Playback schema version: \(major.isEmpty ? "missing" : major)"
            )
        }
        guard let playback = object["playback"] as? [[String: Any]], !playback.isEmpty else {
            throw ServiceError.unavailable("Unified Playback returned no playable resources")
        }
        return object
    }

    /// Whether a resource points at a manifest this shell cannot render.
    ///
    /// `delivery` alone is not the test. The API labels Amazon CENC media
    /// `dash` even though the URL is a single encrypted MP4 the native
    /// decryptor handles — rejecting on the label alone dropped every Amazon
    /// track to Deezer, which is what "it still cannot play" looked like. Only
    /// a URL (or MIME) that really is a segmented manifest is refused.
    static func isSegmentedManifest(_ resource: [String: Any]) -> Bool {
        let address = ((resource["url"] as? String) ?? "").lowercased()
        let mime = ((resource["mime_type"] as? String) ?? "").lowercased()
        if address.contains(".mpd") || mime.contains("dash+xml") || mime.contains("application/dash") {
            return true
        }
        // A `data:` manifest is the API inlining an MPD rather than a media file.
        return address.hasPrefix("data:application/dash")
    }

    static func isHLS(_ resource: [String: Any]) -> Bool {
        let address = ((resource["url"] as? String) ?? "").lowercased()
        let mime = ((resource["mime_type"] as? String) ?? "").lowercased()
        let delivery = ((resource["delivery"] as? String) ?? "").lowercased()
        return delivery == "hls" || mime.contains("mpegurl") || address.contains(".m3u8")
    }

    /// Every resource this client could play, best first.
    ///
    /// The envelope routinely carries more than one entry for a recording — a
    /// manifest next to the media it wraps, or a second source. Taking the
    /// first and failing the whole leg when it happens to be unplayable threw
    /// away a working alternative, so rank them instead:
    ///
    ///   1. plain media with no encryption (nothing to unwrap),
    ///   2. HLS (AVPlayer speaks it natively),
    ///   3. encrypted media the CENC decryptor can turn into a local file.
    ///
    /// Segmented DASH and encrypted HLS are dropped: AVFoundation has no DASH
    /// support, and the decryptor cannot rewrite an HLS playlist.
    static func playableResources(in envelope: [String: Any]) -> [[String: Any]] {
        let playback = envelope["playback"] as? [[String: Any]] ?? []
        let candidates = playback.filter { entry in
            guard let url = entry["url"] as? String, !url.isEmpty else { return false }
            let kind = (entry["kind"] as? String)?.lowercased() ?? ""
            let delivery = (entry["delivery"] as? String)?.lowercased() ?? ""
            guard kind.isEmpty || kind == "audio" || kind == "manifest" else { return false }
            guard delivery.isEmpty || ["direct", "dash", "hls"].contains(delivery) else { return false }
            if isSegmentedManifest(entry) { return false }
            if isHLS(entry), decryptionKey(in: entry) != nil { return false }
            return true
        }
        return candidates.sorted { lhs, rhs in rank(lhs) < rank(rhs) }
    }

    private static func rank(_ resource: [String: Any]) -> Int {
        let encrypted = decryptionKey(in: resource) != nil
        if !encrypted && !isHLS(resource) { return 0 }
        if !encrypted { return 1 }
        return 2
    }

    private static func streamResponse(
        from envelope: [String: Any],
        track: Track,
        quality: PlaybackQuality,
        session: URLSession
    ) async throws -> StreamResponse {
        let candidates = playableResources(in: envelope)
        guard !candidates.isEmpty else {
            throw ServiceError.unavailable(
                "Unified Playback returned no resource native playback can render"
            )
        }
        var lastError: Error = ServiceError.unavailable("Unified Playback returned no usable resource")
        for resource in candidates {
            do {
                return try await streamResponse(
                    from: envelope, resource: resource, track: track, quality: quality, session: session
                )
            } catch {
                // One bad resource is not a dead track: an expired signed URL or
                // a CENC file the decryptor chokes on still leaves the other
                // entries in the envelope worth trying.
                lastError = error
            }
        }
        throw lastError
    }

    private static func streamResponse(
        from envelope: [String: Any],
        resource: [String: Any],
        track: Track,
        quality: PlaybackQuality,
        session: URLSession
    ) async throws -> StreamResponse {
        let sourceToken = ((resource["source"] as? String) ?? (envelope["selected_source"] as? String) ?? "")
            .lowercased()
        // An envelope that names no source at all is still playable — the URL is
        // what matters — so fall back to the in-house source rather than
        // refusing a stream over a missing label.
        let resolved = Self.provider(forSource: sourceToken)
            ?? (sourceToken.isEmpty ? Provider.monochrome : nil)
        guard let provider = resolved else {
            throw ServiceError.unavailable("Unified Playback selected an unsupported source: \(sourceToken)")
        }
        guard let mediaURL = (resource["url"] as? String).flatMap(URL.init(string:)) else {
            throw ServiceError.unavailable("Unified Playback returned no stream URL")
        }

        let key = decryptionKey(in: resource)
        let selected = (resource["quality"] as? String)
            ?? (envelope["quality_requested"] as? String)
            ?? quality.rawValue
        let codec = Self.codec(for: resource, source: sourceToken, selected: selected)

        let playURL: URL
        if let key, !key.isEmpty {
            // Web routes CENC through its service-worker decryptor; native
            // decrypts to a local clear file. The tier, not the container, says
            // whether the encrypted MP4 holds FLAC or AAC.
            playURL = try await AmazonCencDecryptor.decryptFile(
                from: mediaURL,
                keyHex: key,
                codec: codec == "flac" ? "flac" : "mp4a",
                session: session
            )
        } else {
            playURL = mediaURL
        }

        let gain = replayGain(in: resource)
        let durationMillis = ((envelope["track"] as? [String: Any])?["duration_ms"] as? NSNumber)?.doubleValue
        let reportedDuration = durationMillis.map { $0 / 1000 }.flatMap { $0 > 0 ? $0 : nil }
        let mediaDuration = reportedDuration ?? (track.duration > 0 ? track.duration : nil)

        return StreamResponse(
            url: playURL,
            provider: provider,
            quality: selected,
            replayGain: gain.gain,
            peak: gain.peak,
            isPreview: false,
            previewReason: nil,
            mediaDuration: mediaDuration,
            qualityDetail: qualityDetail(in: resource)
        )
    }

    /// The envelope names its own source; only the ones with a native playback
    /// path map to a provider. Anything else fails the leg instead of being
    /// silently badged as something it is not.
    static func provider(forSource source: String) -> Provider? {
        switch source {
        case "amazon": return .amazon
        case "tidal": return .tidal
        case "mono", "monochrome": return .monochrome
        default: return nil
        }
    }

    static func decryptionKey(in resource: [String: Any]) -> String? {
        if let key = resource["decryption_key"] as? String { return key }
        if let key = resource["decryptionKey"] as? String { return key }
        if let encryption = resource["encryption"] as? [String: Any] {
            if let key = encryption["key"] as? [String: Any], let value = key["value"] as? String { return value }
            if let value = encryption["key"] as? String { return value }
        }
        if let decryption = resource["decryption"] as? [String: Any] {
            if let key = decryption["key"] as? [String: Any], let value = key["value"] as? String { return value }
            if let value = decryption["key"] as? String { return value }
        }
        if let drm = resource["drm"] as? [String: Any] {
            if let value = drm["decryption_key"] as? String { return value }
            if let value = drm["decryptionKey"] as? String { return value }
        }
        return nil
    }

    /// Mirrors web `getUnifiedPlaybackCodec`: Amazon states a tier rather than a
    /// codec, and the tier is what says whether the encrypted MP4 holds FLAC or
    /// AAC — exactly what the CENC sample-entry rewrite needs to know.
    static func codec(for resource: [String: Any], source: String, selected: String) -> String? {
        let tier = selected.uppercased()
        if tier.hasPrefix("DOLBY_ATMOS_AC4_") { return "ac4" }
        if tier.hasPrefix("DOLBY_ATMOS_EAC3_") || tier == "DOLBY_ATMOS" { return "eac3-joc" }
        if source == "amazon" {
            let head = tier.split(separator: "_").first.map(String.init) ?? tier
            if ["UHD", "HD"].contains(head) || tier == "HI_RES_LOSSLESS" || tier == "LOSSLESS" { return "flac" }
            if ["SD", "HIGH", "LOW"].contains(head) { return "opus" }
        }
        return (resource["codec"] as? String)?.lowercased()
    }

    static func replayGain(in resource: [String: Any]) -> (gain: Double?, peak: Double?) {
        let rg = (resource["replay_gain"] as? [String: Any]) ?? (resource["replayGain"] as? [String: Any]) ?? [:]
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                let raw = rg[key] ?? resource[key]
                if let value = raw as? NSNumber { return value.doubleValue }
                if let text = raw as? String, let value = Double(text) { return value }
            }
            return nil
        }
        return (number(["track_gain_db", "trackGainDb"]), number(["track_peak", "trackPeak"]))
    }

    /// `24/96`-style detail for the tier the API actually served, so HD and UHD
    /// can be told apart at a glance the way they are on web.
    static func qualityDetail(in resource: [String: Any]) -> String? {
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                if let value = resource[key] as? NSNumber { return value.doubleValue }
            }
            return nil
        }
        guard let bitDepth = number(["bit_depth", "bitDepth"]),
              let sampleRate = number(["sample_rate_hz", "sampleRateHz", "sample_rate", "sampleRate"]),
              bitDepth > 0, sampleRate > 0 else { return nil }
        let kHz = sampleRate / 1000
        let rate = kHz == 44.1 ? "44.1" : String(Int(kHz.rounded()))
        return "\(Int(bitDepth))/\(rate)"
    }
}
