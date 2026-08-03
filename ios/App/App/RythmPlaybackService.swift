import Foundation

/// Rythm playback resolver (`track-api.monochrome.tf`, FastAPI 2.2.0).
///
/// Unlike the other legs this is a *server-side* aggregator: it runs the
/// Monochrome/Qobuz/Amazon/Deezer chain itself and answers with one already
/// resolved stream URL. It matches on song name + artist (ISRC and duration
/// only narrow the match), so it needs no catalog ID and keeps working while
/// the HiFi instance pool answers `Upstream API error` for `/track/`.
///
/// `/playback` is session-gated the same way Amazon's `/api/track/` is: solve
/// Cloudflare Turnstile on the `monochrome.tf` origin, exchange it at
/// `/auth/turnstile`, then send the bearer token. A `bypass_token` skips the
/// challenge entirely when the user has one.
enum RythmPlaybackService {
    /// Where the `/playback` bearer comes from. Production solves Turnstile in a
    /// WKWebView, which needs a foreground window and a real Cloudflare round
    /// trip — neither exists in a test bundle, so the seam lets the session
    /// handling (first solve, 401 re-solve, single retry) be exercised directly.
    static var sessionTokenProvider: (_ base: String, _ forceRefresh: Bool) async throws -> String = {
        base, forceRefresh in
        try await AmazonTurnstileAuth.shared.accessToken(
            apiBaseURL: base,
            exchange: .rythm,
            siteKey: PlaybackSourceSettings.rythmTurnstileSiteKey,
            forceRefresh: forceRefresh
        )
    }

    /// `quality` is accepted for call-site symmetry with the other resolvers but
    /// deliberately not sent: `PlaybackRequest` has no tier field, so the badge
    /// is read off the media URL Rythm actually returns rather than the tier the
    /// user asked for — the same rule the direct-media path uses.
    static func resolveStream(
        for track: Track,
        quality: PlaybackQuality,
        session: URLSession = .shared
    ) async throws -> StreamResponse {
        guard PlaybackSourceSettings.rythmEnabled else {
            throw ServiceError.unavailable("Rythm disabled")
        }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            throw ServiceError.unavailable("Rythm lookup needs title and artist")
        }

        let base = PlaybackSourceSettings.rythmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bypass = PlaybackSourceSettings.rythmBypassToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var bearer: String?
        if bypass.isEmpty {
            bearer = try await sessionTokenProvider(base, false)
        }

        do {
            return try await fetchPlayback(
                track: track, title: title, artist: artist,
                base: base, bypass: bypass, bearer: bearer, session: session
            )
        } catch let error as ServiceError {
            // `session_required` / `session_expired` arrive as 401 or 403 once the
            // hour-long session lapses. Re-solve once with a fresh token rather
            // than handing the track to a fallback that is very likely dead.
            guard case .http(let status) = error, status == 401 || status == 403 else { throw error }
            await AmazonTurnstileAuth.shared.clearCache(for: .rythm)
            let fresh = try await sessionTokenProvider(base, true)
            return try await fetchPlayback(
                track: track, title: title, artist: artist,
                base: base, bypass: "", bearer: fresh, session: session
            )
        }
    }

    private static func fetchPlayback(
        track: Track,
        title: String,
        artist: String,
        base: String,
        bypass: String,
        bearer: String?,
        session: URLSession,
        timeout: TimeInterval = 30
    ) async throws -> StreamResponse {
        var components = URLComponents(string: base + "/playback")
        if !bypass.isEmpty {
            components?.queryItems = [URLQueryItem(name: "bypass_token", value: bypass)]
        }
        guard let url = components?.url else { throw ServiceError.invalidResponse }

        var body: [String: Any] = ["song_name": String(title.prefix(300)), "artist": String(artist.prefix(300))]
        // The schema rejects an ISRC outside 5…32 characters and a non-positive
        // duration, and a 422 costs the whole leg — so send them only when valid.
        if let isrc = track.isrc?.trimmingCharacters(in: .whitespacesAndNewlines),
           (5...32).contains(isrc.count) {
            body["isrc"] = isrc
        }
        if track.duration > 0 { body["duration"] = track.duration }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        MusicService.webRequestHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ServiceError.unavailable("Rythm playback lookup timed out at \(base)")
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // 401/403 must stay structured — the caller re-solves the session on
            // those and only those.
            if http.statusCode == 401 || http.statusCode == 403 { throw ServiceError.http(http.statusCode) }
            if let detail = AmazonTurnstileAuth.exchangeErrorDetail(in: data) {
                throw ServiceError.unavailable("Rythm: \(detail)")
            }
            throw ServiceError.http(http.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = object["url"] as? String,
              let streamURL = URL(string: stream) else {
            throw ServiceError.unavailable("Rythm returned no stream URL")
        }

        let catalogDuration: Double? = track.duration > 0 ? track.duration : nil
        let duration = (object["duration_seconds"] as? NSNumber)?.doubleValue ?? catalogDuration
        let token = PlaybackQuality.mediaFormatToken(mimeType: nil, url: streamURL)
            ?? track.catalogQuality?.rawValue
            ?? "UNKNOWN"
        // No Monochrome origin headers here: unlike the Deezer leg, the URL this
        // returns points at whichever upstream CDN Rythm resolved, and those sign
        // their own requests — stamping a foreign Origin on the media GET is at
        // best ignored and at worst a 403.
        return StreamResponse(
            url: streamURL,
            provider: .rythm,
            quality: token,
            replayGain: nil,
            peak: nil,
            isPreview: false,
            previewReason: nil,
            mediaDuration: duration
        )
    }
}
