import XCTest
import Foundation
@testable import App

/// Exercises the Unified Playback resolver against a stubbed transport.
///
/// The stubs mirror shapes taken from the live `music-api.geeked.wtf` envelope
/// the web client reads, so a contract drift on either side fails here instead
/// of surfacing as a silent fall-through to Deezer:
///
///   * `GET /api/v2/track/?track=…&artist=…&intent=stream&quality=…`
///     → `{"schema_version", "track", "quality_requested", "playback": [ … ]}`
///   * each playback entry carries `{url, kind, delivery, source, quality,
///     mime_type, bit_depth, sample_rate_hz, replay_gain, encryption?}`
///   * missing/rejected Turnstile JWT → `401` / `428`
///   * unresolvable recording → `404` (or `502` from the upstream)
///   * client over its quota → `429`
final class UnifiedPlaybackTests: XCTestCase {
    private var session: URLSession!
    private var defaultsBackup: [String: Any?] = [:]
    private var providerBackup: ((String, Bool) async throws -> String)!

    private static let settingKeys = [
        "native.unifiedEnabled",
        "native.unifiedApiBaseURL",
        "native.unifiedApiToken",
        "native.unifiedTurnstileSiteKey",
        "native.unifiedTurnstileAction",
        "native.unifiedRateLimitedUntil",
        AmazonTurnstileAuth.Exchange.unified.tokenKey,
        AmazonTurnstileAuth.Exchange.unified.expiryKey,
    ]

    override func setUp() {
        super.setUp()
        for key in Self.settingKeys {
            defaultsBackup[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        providerBackup = UnifiedPlaybackService.sessionTokenProvider
        UnifiedStub.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnifiedStub.self]
        session = URLSession(configuration: configuration)

        // The default (shared) token always solves, so give every test a solver
        // that answers instead of reaching for a WKWebView. Tests that care how
        // often it ran install their own recording solver.
        UnifiedPlaybackService.sessionTokenProvider = { _, forceRefresh in
            forceRefresh ? "jwt-refreshed" : "jwt-cached"
        }
    }

    override func tearDown() {
        for (key, value) in defaultsBackup {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        defaultsBackup = [:]
        UnifiedPlaybackService.sessionTokenProvider = providerBackup
        UnifiedStub.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - Guards that must not spend a request

    func testDisabledResolverFailsWithoutCallingTheAPI() async {
        PlaybackSourceSettings.unifiedEnabled = false
        UnifiedStub.enqueue(ok: Self.envelope())

        await assertFails(Self.track(), matching: "Unified Playback disabled")
        XCTAssertTrue(UnifiedStub.requests.isEmpty)
    }

    func testEnabledDefaultsToOnWhenUnset() {
        XCTAssertTrue(PlaybackSourceSettings.unifiedEnabled)
    }

    func testBlankTitleFailsWithoutCallingTheAPI() async {
        await assertFails(Self.track(title: "   "), matching: "needs a track title")
        XCTAssertTrue(UnifiedStub.requests.isEmpty)
    }

    func testRateLimitedClientFailsWithoutCallingTheAPI() async {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 600, forKey: "native.unifiedRateLimitedUntil")
        UnifiedStub.enqueue(ok: Self.envelope())

        await assertFails(Self.track(), matching: "rate limiting")
        XCTAssertTrue(UnifiedStub.requests.isEmpty)
    }

    // MARK: - Defaults that must track the web client

    func testDefaultsMatchTheWebBundle() {
        XCTAssertEqual(PlaybackSourceSettings.unifiedApiBaseURL, "https://music-api.geeked.wtf")
        XCTAssertEqual(PlaybackSourceSettings.unifiedApiToken,
                       PlaybackSourceSettings.defaultUnifiedApiToken)
        XCTAssertEqual(PlaybackSourceSettings.unifiedTurnstileSiteKey, "0x4AAAAAADgxqF6QVMm0GLHH")
        XCTAssertEqual(PlaybackSourceSettings.unifiedTurnstileAction, "auth")
    }

    func testLegacyBaseURLsAreMigratedToTheCurrentHost() {
        // Web keeps the same list and refuses to read a stored value naming one
        // of them, so a client left pointing at the old Amazon or Rythm host is
        // moved instead of stranded on a dead endpoint.
        for legacy in ["https://amz.geeked.wtf", "https://track-api.monochrome.tf", "https://mono.geeked.wtf"] {
            PlaybackSourceSettings.unifiedApiBaseURL = legacy
            XCTAssertEqual(PlaybackSourceSettings.unifiedApiBaseURL, "https://music-api.geeked.wtf", legacy)
            PlaybackSourceSettings.unifiedApiBaseURL = legacy + "/"
            XCTAssertEqual(PlaybackSourceSettings.unifiedApiBaseURL, "https://music-api.geeked.wtf", legacy)
        }
    }

    func testCustomBaseURLIsHonoured() {
        PlaybackSourceSettings.unifiedApiBaseURL = "https://staging.example"
        XCTAssertEqual(PlaybackSourceSettings.unifiedApiBaseURL, "https://staging.example")
    }

    func testUnifiedExchangeMatchesTheAPIContract() {
        let unified = AmazonTurnstileAuth.Exchange.unified
        XCTAssertEqual(unified.path, "/api/auth/turnstile")
        XCTAssertEqual(unified.tokenField, "turnstile_token")
        XCTAssertNotEqual(unified.tokenKey, AmazonTurnstileAuth.Exchange.amazon.tokenKey)
    }

    // MARK: - Request shaping

    func testSendsTheLookupTheAPIExpects() async throws {
        UnifiedStub.enqueue(ok: Self.envelope())
        _ = try await resolve(
            Self.track(title: "  Ghosts 'n' Stuff  ", artist: " deadmau5 ", isrc: "gbtdg0900132"),
            quality: .hiResLossless
        )

        let request = try XCTUnwrap(UnifiedStub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "music-api.geeked.wtf")
        XCTAssertTrue(request.url?.path.hasPrefix("/api/v2/track") == true, request.url?.path ?? "")
        XCTAssertEqual(Self.queryValue("track", in: request), "Ghosts 'n' Stuff")
        XCTAssertEqual(Self.queryValue("artist", in: request), "deadmau5")
        XCTAssertEqual(Self.queryValue("album", in: request), "4x4=12")
        XCTAssertEqual(Self.queryValue("isrc", in: request), "GBTDG0900132")
        XCTAssertEqual(Self.queryValue("duration", in: request), "191")
        XCTAssertEqual(Self.queryValue("intent", in: request), "stream")
        XCTAssertEqual(Self.queryValue("quality", in: request), "HI_RES_LOSSLESS")
    }

    func testOmitsNarrowersTheTrackDoesNotHave() async throws {
        UnifiedStub.enqueue(ok: Self.envelope())
        _ = try await resolve(Self.track(album: nil, duration: 0, isrc: nil))

        let request = try XCTUnwrap(UnifiedStub.requests.first)
        XCTAssertNil(Self.queryValue("album", in: request))
        XCTAssertNil(Self.queryValue("duration", in: request))
        XCTAssertNil(Self.queryValue("isrc", in: request))
        XCTAssertEqual(Self.queryValue("track", in: request), "Ghosts 'n' Stuff")
    }

    func testSendsTheBearerTokenAndTheMonochromeWebOrigin() async throws {
        UnifiedStub.enqueue(ok: Self.envelope())
        _ = try await resolve(Self.track())

        let request = try XCTUnwrap(UnifiedStub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(PlaybackSourceSettings.defaultUnifiedApiToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://monochrome.tf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://monochrome.tf/")
    }

    func testDownloadIntentIsSentWhenAsked() async throws {
        UnifiedStub.enqueue(ok: Self.envelope())
        _ = try await UnifiedPlaybackService.resolveStream(
            for: Self.track(), quality: .lossless, intent: "download", session: session
        )
        XCTAssertEqual(Self.queryValue("intent", in: try XCTUnwrap(UnifiedStub.requests.first)), "download")
    }

    // MARK: - Turnstile session

    func testSharedTokenSolvesTurnstileUpFront() async throws {
        var solves: [Bool] = []
        var bases: [String] = []
        UnifiedPlaybackService.sessionTokenProvider = { base, force in
            solves.append(force)
            bases.append(base)
            return "jwt-cached"
        }
        UnifiedStub.enqueue(ok: Self.envelope())
        _ = try await resolve(Self.track())

        XCTAssertEqual(solves, [false])
        XCTAssertEqual(bases, ["https://music-api.geeked.wtf"])
        XCTAssertEqual(UnifiedStub.requests.first?.value(forHTTPHeaderField: "X-Turnstile-JWT"), "jwt-cached")
    }

    func testPrivateTokenSendsNoJwtUntilTheAPIAsksForOne() async throws {
        PlaybackSourceSettings.unifiedApiToken = "amp_private"
        UnifiedPlaybackService.sessionTokenProvider = { _, _ in
            XCTFail("unexpected Turnstile solve")
            throw ServiceError.unavailable("unexpected solve")
        }
        UnifiedStub.enqueue(ok: Self.envelope())
        _ = try await resolve(Self.track())

        let request = try XCTUnwrap(UnifiedStub.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Turnstile-JWT"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer amp_private")
    }

    func testRejectedJwtIsResolvedWithOneForcedResolve() async throws {
        for status in [401, 428] {
            UnifiedStub.reset()
            var solves: [Bool] = []
            UnifiedPlaybackService.sessionTokenProvider = { _, force in
                solves.append(force)
                return force ? "jwt-refreshed" : "jwt-cached"
            }
            UnifiedStub.enqueue(status: status, body: #"{"detail":"turnstile_required"}"#)
            UnifiedStub.enqueue(ok: Self.envelope())

            let stream = try await resolve(Self.track())
            XCTAssertEqual(stream.url.absoluteString, "https://cdn.example/audio/track.flac", "\(status)")
            XCTAssertEqual(solves, [false, true], "\(status)")
            XCTAssertEqual(UnifiedStub.requests.count, 2, "\(status)")
            XCTAssertEqual(UnifiedStub.requests.last?.value(forHTTPHeaderField: "X-Turnstile-JWT"),
                           "jwt-refreshed", "\(status)")
        }
    }

    func testASecondRejectionEndsTheLeg() async {
        UnifiedStub.enqueue(status: 401, body: #"{"detail":"turnstile_required"}"#)
        UnifiedStub.enqueue(status: 401, body: #"{"detail":"turnstile_required"}"#)

        await assertFails(Self.track(), matching: "401")
        XCTAssertEqual(UnifiedStub.requests.count, 2)
    }

    // MARK: - Failure statuses

    func testRateLimitTakesTheLegOutForTheWholeSession() async {
        UnifiedStub.enqueue(status: 429, body: #"{"detail":"rate limited"}"#)
        await assertFails(Self.track(), matching: "rate limiting")
        XCTAssertTrue(UnifiedPlaybackService.isRateLimited)

        UnifiedStub.enqueue(ok: Self.envelope())
        await assertFails(Self.track(), matching: "rate limiting")
        // The second play must not spend a request to relearn the limit.
        XCTAssertEqual(UnifiedStub.requests.count, 1)

        UnifiedPlaybackService.clearRateLimit()
        XCTAssertFalse(UnifiedPlaybackService.isRateLimited)
    }

    func testUnresolvableRecordingReportsNoPlayableSource() async {
        for status in [404, 502] {
            UnifiedStub.reset()
            UnifiedStub.enqueue(status: status, body: #"{"sources":[]}"#)
            await assertFails(Self.track(), matching: "found no playable source")
        }
    }

    func testUnknownSchemaVersionIsRefused() async {
        UnifiedStub.enqueue(ok: Self.envelope(schemaVersion: "3.0"))
        await assertFails(Self.track(), matching: "Unsupported Unified Playback schema version")
    }

    func testEmptyPlaybackListIsRefused() async {
        UnifiedStub.enqueue(ok: #"{"schema_version":"2.0","playback":[]}"#)
        await assertFails(Self.track(), matching: "no playable resources")
    }

    func testUnsupportedSourceIsRefused() async {
        UnifiedStub.enqueue(ok: Self.envelope(source: "qobuz"))
        await assertFails(Self.track(), matching: "unsupported source: qobuz")
    }

    // MARK: - Envelope reading

    func testResolvesADirectMonochromeStream() async throws {
        UnifiedStub.enqueue(ok: Self.envelope(source: "mono", quality: "LOSSLESS"))
        let stream = try await resolve(Self.track())

        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example/audio/track.flac")
        XCTAssertEqual(stream.provider, .monochrome)
        XCTAssertEqual(stream.quality, "LOSSLESS")
        XCTAssertEqual(stream.qualityDetail, "24/96")
        XCTAssertEqual(stream.replayGain ?? 0, -7.5, accuracy: 0.001)
        XCTAssertEqual(stream.peak ?? 0, 0.98, accuracy: 0.001)
        // `duration_ms` from the envelope wins over the catalog's figure.
        XCTAssertEqual(stream.mediaDuration ?? 0, 194.5, accuracy: 0.001)
    }

    func testAmazonTierIsReportedAsTheProviderStatesIt() async throws {
        UnifiedStub.enqueue(ok: Self.envelope(source: "amazon", quality: "UHD_96_24"))
        let stream = try await resolve(Self.track())

        XCTAssertEqual(stream.provider, .amazon)
        XCTAssertEqual(stream.quality, "UHD_96_24")
        XCTAssertEqual(PlaybackQuality(providerToken: stream.quality), .hiResLossless)
    }

    func testHLSDeliveryPlaysDirectly() async throws {
        UnifiedStub.enqueue(ok: Self.envelope(
            url: "https://cdn.example/audio/master.m3u8",
            delivery: "hls",
            mimeType: "application/vnd.apple.mpegurl"
        ))
        let stream = try await resolve(Self.track())
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example/audio/master.m3u8")
    }

    func testDashManifestIsRefusedSoTheTrackCanFallToDeezer() async {
        // AVPlayer has no DASH support; web only plays those through shaka.
        UnifiedStub.enqueue(ok: Self.envelope(
            url: "https://cdn.example/audio/manifest.mpd",
            kind: "manifest",
            delivery: "dash",
            mimeType: "application/dash+xml"
        ))
        await assertFails(Self.track(), matching: "DASH manifest")
    }

    func testEncryptedHLSIsRefusedRatherThanHandedToTheDecryptor() async {
        UnifiedStub.enqueue(ok: Self.envelope(
            url: "https://cdn.example/audio/master.m3u8",
            delivery: "hls",
            mimeType: "application/vnd.apple.mpegurl",
            encryptionKey: "00112233445566778899aabbccddeeff"
        ))
        await assertFails(Self.track(), matching: "encrypted HLS")
    }

    func testSkipsResourcesThisClientCannotPlay() async throws {
        // A lyrics/artwork entry ahead of the audio must not be chosen.
        let body = """
        {"schema_version":"2.0","playback":[
          {"kind":"image","delivery":"direct","url":"https://cdn.example/cover.jpg","source":"mono"},
          {"kind":"audio","delivery":"direct","source":"mono","quality":"LOSSLESS",
           "url":"https://cdn.example/audio/track.flac","mime_type":"audio/flac"}
        ]}
        """
        UnifiedStub.enqueue(ok: body)
        let stream = try await resolve(Self.track())
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example/audio/track.flac")
    }

    // MARK: - Pure helpers

    func testSourceMapping() {
        XCTAssertEqual(UnifiedPlaybackService.provider(forSource: "amazon"), .amazon)
        XCTAssertEqual(UnifiedPlaybackService.provider(forSource: "tidal"), .tidal)
        XCTAssertEqual(UnifiedPlaybackService.provider(forSource: "mono"), .monochrome)
        XCTAssertEqual(UnifiedPlaybackService.provider(forSource: "monochrome"), .monochrome)
        XCTAssertNil(UnifiedPlaybackService.provider(forSource: "deezer"))
        XCTAssertNil(UnifiedPlaybackService.provider(forSource: ""))
    }

    func testCodecFollowsTheAmazonTierNotTheContainer() {
        // The tier is what says whether the encrypted MP4 holds FLAC or AAC, and
        // that drives the CENC sample-entry rewrite.
        XCTAssertEqual(UnifiedPlaybackService.codec(for: [:], source: "amazon", selected: "UHD_96_24"), "flac")
        XCTAssertEqual(UnifiedPlaybackService.codec(for: [:], source: "amazon", selected: "HD_44_1_16"), "flac")
        XCTAssertEqual(UnifiedPlaybackService.codec(for: [:], source: "amazon", selected: "LOSSLESS"), "flac")
        XCTAssertEqual(UnifiedPlaybackService.codec(for: [:], source: "amazon", selected: "SD_HIGH"), "opus")
        XCTAssertEqual(UnifiedPlaybackService.codec(for: [:], source: "amazon", selected: "LOW"), "opus")
        XCTAssertEqual(UnifiedPlaybackService.codec(for: [:], source: "amazon", selected: "DOLBY_ATMOS_AC4_HIGH"), "ac4")
        XCTAssertEqual(UnifiedPlaybackService.codec(for: [:], source: "amazon", selected: "DOLBY_ATMOS_EAC3_LOW"), "eac3-joc")
        XCTAssertEqual(
            UnifiedPlaybackService.codec(for: ["codec": "FLAC"], source: "mono", selected: "LOSSLESS"),
            "flac"
        )
    }

    func testDecryptionKeyIsReadFromEveryShapeTheAPIUses() {
        XCTAssertEqual(UnifiedPlaybackService.decryptionKey(in: ["decryption_key": "aa"]), "aa")
        XCTAssertEqual(UnifiedPlaybackService.decryptionKey(in: ["decryptionKey": "bb"]), "bb")
        XCTAssertEqual(
            UnifiedPlaybackService.decryptionKey(in: ["encryption": ["key": ["value": "cc"]]]),
            "cc"
        )
        XCTAssertEqual(UnifiedPlaybackService.decryptionKey(in: ["drm": ["decryption_key": "dd"]]), "dd")
        XCTAssertNil(UnifiedPlaybackService.decryptionKey(in: ["url": "https://cdn.example/a.flac"]))
    }

    func testQualityDetailReadsBitDepthAndSampleRate() {
        XCTAssertEqual(
            UnifiedPlaybackService.qualityDetail(in: ["bit_depth": 16, "sample_rate_hz": 44100]),
            "16/44.1"
        )
        XCTAssertEqual(
            UnifiedPlaybackService.qualityDetail(in: ["bitDepth": 24, "sampleRateHz": 96000]),
            "24/96"
        )
        XCTAssertNil(UnifiedPlaybackService.qualityDetail(in: ["bit_depth": 24]))
    }

    // MARK: - Prewarm

    func testPrewarmTargetsUnifiedOnlyForTheSharedToken() {
        let target = AmazonTurnstileAuth.prewarmTarget()
        XCTAssertEqual(target?.exchange.id, "unified")
        XCTAssertEqual(target?.base, "https://music-api.geeked.wtf")
        XCTAssertEqual(target?.siteKey, "0x4AAAAAADgxqF6QVMm0GLHH")
        XCTAssertEqual(target?.action, "auth")
    }

    func testPrewarmDoesNothingForAPrivateTokenOrADisabledLeg() {
        // A client with its own token is admitted without a JWT, so solving at
        // launch would put a Cloudflare card on screen for nothing.
        PlaybackSourceSettings.unifiedApiToken = "amp_private"
        XCTAssertNil(AmazonTurnstileAuth.prewarmTarget())

        PlaybackSourceSettings.unifiedApiToken = PlaybackSourceSettings.defaultUnifiedApiToken
        PlaybackSourceSettings.unifiedEnabled = false
        XCTAssertNil(AmazonTurnstileAuth.prewarmTarget())
    }

    func testChallengeRendersTheActionTheExchangeVerifies() {
        for mode in [AmazonTurnstileAuth.ChallengeMode.interactionOnly, .alwaysVisible] {
            let html = AmazonTurnstileAuth.challengeHTML(siteKey: "0xTEST", mode: mode, action: "auth")
            XCTAssertTrue(html.contains("action: 'auth',"), "\(mode)")
        }
    }

    func testChallengeOmitsTheActionEntirelyWhenThereIsNone() {
        // An empty `action: ''` is not the same as no action — an exchange that
        // does not check it accepts a token with neither, and would reject one
        // carrying an empty string.
        let html = AmazonTurnstileAuth.challengeHTML(siteKey: "0xTEST", mode: .interactionOnly, action: "")
        XCTAssertFalse(html.contains("action:"))
    }

    func testChallengeActionIsEscapedLikeTheSiteKey() {
        let html = AmazonTurnstileAuth.challengeHTML(
            siteKey: "0xTEST", mode: .interactionOnly, action: "a'\\b"
        )
        XCTAssertTrue(html.contains("action: 'a\\'\\\\b',"))
    }

    // MARK: - Helpers

    private func resolve(
        _ track: Track,
        quality: PlaybackQuality = .lossless
    ) async throws -> StreamResponse {
        try await UnifiedPlaybackService.resolveStream(for: track, quality: quality, session: session)
    }

    private func assertFails(
        _ track: Track,
        matching fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let stream = try await resolve(track)
            XCTFail("expected a failure, resolved \(stream.url)", file: file, line: line)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(message.contains(fragment),
                          "\"\(message)\" does not contain \"\(fragment)\"",
                          file: file, line: line)
        }
    }

    private static func track(
        title: String = "Ghosts 'n' Stuff",
        artist: String = "deadmau5",
        album: String? = "4x4=12",
        duration: Double = 191,
        isrc: String? = nil
    ) -> Track {
        Track(id: "tidal:447580805", title: title,
              artist: Artist(id: "3523908", name: artist),
              album: album.map { AlbumSummary(id: "447580800", title: $0, cover: nil) },
              duration: duration, isrc: isrc)
    }

    private static func envelope(
        schemaVersion: String = "2.0",
        url: String = "https://cdn.example/audio/track.flac",
        kind: String = "audio",
        delivery: String = "direct",
        source: String = "mono",
        quality: String = "LOSSLESS",
        mimeType: String = "audio/flac",
        encryptionKey: String? = nil
    ) -> String {
        var resource: [String: Any] = [
            "kind": kind,
            "delivery": delivery,
            "source": source,
            "quality": quality,
            "url": url,
            "mime_type": mimeType,
            "bit_depth": 24,
            "sample_rate_hz": 96000,
            "channels": 2,
            "replay_gain": ["track_gain_db": -7.5, "track_peak": 0.98],
        ]
        if let encryptionKey {
            resource["encryption"] = ["key": ["value": encryptionKey], "key_id": "0123456789abcdef"]
        }
        let object: [String: Any] = [
            "schema_version": schemaVersion,
            "request_id": "req-1",
            "intent": "stream",
            "quality_requested": "HI_RES_LOSSLESS",
            "selected_source": source,
            "track": ["id": "B00TESTASIN", "duration_ms": 194500],
            "playback": [resource],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func queryValue(_ name: String, in request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }
}

/// Serves queued responses and records what the resolver actually sent.
final class UnifiedStub: URLProtocol {
    struct Response {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
    }

    private static let lock = NSLock()
    private static var queue: [Response] = []
    private static var seen: [URLRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        seen = []
    }

    static func enqueue(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        queue.append(Response(status: status, body: Data(body.utf8)))
    }

    static func enqueue(ok body: String) { enqueue(status: 200, body: body) }

    static func enqueue(error: Error) {
        lock.lock(); defer { lock.unlock() }
        queue.append(Response(error: error))
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let next = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = next.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
