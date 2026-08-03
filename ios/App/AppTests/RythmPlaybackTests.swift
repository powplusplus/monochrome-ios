import XCTest
import Foundation
@testable import App

/// Exercises the Rythm resolver against a stubbed transport.
///
/// The stubs mirror shapes taken from the live `track-api.monochrome.tf`
/// (FastAPI 2.2.0) service, so a contract drift on either side fails here
/// instead of surfacing as a silent fall-through to the legacy chain:
///
///   * `POST /playback` → `{"url", "track_id", "recording_id", "title",
///     "artists", "isrc"?, "duration_seconds"?}`
///   * missing/expired session → `401 {"detail":{"code":"session_required"}}`
///   * bad bearer → `401 {"detail":{"code":"invalid_session"}}`
///   * header without the `Bearer` prefix → `401 {"detail":{"code":
///     "invalid_authorization_header"}}`
///   * schema violation → `422 {"detail":[{...}]}` — an array, not an object
final class RythmPlaybackTests: XCTestCase {
    private var session: URLSession!
    private var defaultsBackup: [String: Any?] = [:]
    private var providerBackup: ((String, Bool) async throws -> String)!

    private static let settingKeys = [
        "native.rythmEnabled",
        "native.rythmBaseURL",
        "native.rythmBypassToken",
        "native.rythmTurnstileSiteKey",
        "native.rythmTurnstileAction",
        "native.amazonTurnstileAction",
        "native.amazonEnabled",
        "native.amazonApiBaseURL",
        "native.amazonBypassToken",
        "native.amazonTurnstileSiteKey",
    ]

    override func setUp() {
        super.setUp()
        for key in Self.settingKeys {
            defaultsBackup[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        providerBackup = RythmPlaybackService.sessionTokenProvider
        RythmStub.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RythmStub.self]
        session = URLSession(configuration: configuration)

        // Default to the bypass path so a test that does not care about session
        // handling never reaches the Turnstile solver.
        PlaybackSourceSettings.rythmBypassToken = "test-bypass"
        RythmPlaybackService.sessionTokenProvider = { _, _ in
            XCTFail("unexpected Turnstile solve")
            throw ServiceError.unavailable("unexpected solve")
        }
    }

    override func tearDown() {
        for (key, value) in defaultsBackup {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        defaultsBackup = [:]
        RythmPlaybackService.sessionTokenProvider = providerBackup
        RythmStub.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - Guards that must not spend a request

    func testDisabledResolverFailsWithoutCallingTheAPI() async {
        PlaybackSourceSettings.rythmEnabled = false
        RythmStub.enqueue(ok: Self.playbackBody())

        await assertFails(Self.track(), matching: "Rythm disabled")
        XCTAssertTrue(RythmStub.requests.isEmpty)
    }

    func testEnabledDefaultsToOnWhenUnset() {
        XCTAssertTrue(PlaybackSourceSettings.rythmEnabled)
    }

    func testBlankTitleFailsWithoutCallingTheAPI() async {
        // `song_name` has minLength 1 — sending it would burn a 422.
        await assertFails(Self.track(title: "   "), matching: "needs title and artist")
        XCTAssertTrue(RythmStub.requests.isEmpty)
    }

    func testBlankArtistFailsWithoutCallingTheAPI() async {
        await assertFails(Self.track(artist: ""), matching: "needs title and artist")
        XCTAssertTrue(RythmStub.requests.isEmpty)
    }

    // MARK: - Request shaping

    func testPostsTrimmedNameAndArtistToPlaybackPath() async throws {
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track(title: "  Ghosts 'n' Stuff  ", artist: " deadmau5 "))

        let request = try XCTUnwrap(RythmStub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/playback")
        XCTAssertEqual(request.url?.host, "track-api.monochrome.tf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let body = try XCTUnwrap(RythmStub.bodies.first)
        XCTAssertEqual(body["song_name"] as? String, "Ghosts 'n' Stuff")
        XCTAssertEqual(body["artist"] as? String, "deadmau5")
    }

    func testSendsTheMonochromeWebOriginTheAPIGatesOn() async throws {
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track())

        let request = try XCTUnwrap(RythmStub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://monochrome.tf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://monochrome.tf/")
    }

    func testTrailingSlashInTheBaseURLDoesNotDoubleUpThePath() async throws {
        PlaybackSourceSettings.rythmBaseURL = "https://track-api.monochrome.tf/"
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track())

        XCTAssertEqual(RythmStub.requests.first?.url?.absoluteString,
                       "https://track-api.monochrome.tf/playback?bypass_token=test-bypass")
    }

    func testNameAndArtistAreTruncatedToTheSchemaMaximum() async throws {
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track(title: String(repeating: "t", count: 400),
                                         artist: String(repeating: "a", count: 400)))

        let body = try XCTUnwrap(RythmStub.bodies.first)
        // maxLength 300 on both fields; over that the whole leg costs a 422.
        XCTAssertEqual((body["song_name"] as? String)?.count, 300)
        XCTAssertEqual((body["artist"] as? String)?.count, 300)
    }

    func testValidISRCIsSent() async throws {
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track(isrc: "GBTDG0900132"))
        XCTAssertEqual(RythmStub.bodies.first?["isrc"] as? String, "GBTDG0900132")
    }

    func testOutOfRangeISRCIsOmittedRatherThanRejected() async throws {
        // The schema takes 5…32 characters; anything else is a 422 for the whole
        // request, even though the ISRC only narrows the match.
        for isrc in ["", "  ", "AB", "GBTD", String(repeating: "X", count: 33)] {
            RythmStub.reset()
            RythmStub.enqueue(ok: Self.playbackBody())
            _ = try await resolve(Self.track(isrc: isrc))
            XCTAssertNil(RythmStub.bodies.first?["isrc"], "isrc \"\(isrc)\"")
        }
    }

    func testISRCBoundariesAreInclusive() async throws {
        for isrc in [String(repeating: "X", count: 5), String(repeating: "X", count: 32)] {
            RythmStub.reset()
            RythmStub.enqueue(ok: Self.playbackBody())
            _ = try await resolve(Self.track(isrc: isrc))
            XCTAssertEqual(RythmStub.bodies.first?["isrc"] as? String, isrc)
        }
    }

    func testPositiveDurationIsSent() async throws {
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track(duration: 191))
        XCTAssertEqual((RythmStub.bodies.first?["duration"] as? NSNumber)?.doubleValue, 191)
    }

    func testNonPositiveDurationIsOmitted() async throws {
        // `exclusiveMinimum: 0` — a search card with no duration must not 422.
        for duration in [0.0, -1.0] {
            RythmStub.reset()
            RythmStub.enqueue(ok: Self.playbackBody())
            _ = try await resolve(Self.track(duration: duration))
            XCTAssertNil(RythmStub.bodies.first?["duration"], "duration \(duration)")
        }
    }

    func testBodyCarriesNothingBeyondTheSchema() async throws {
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track(duration: 191, isrc: "GBTDG0900132"))
        let keys = Set(try XCTUnwrap(RythmStub.bodies.first).keys)
        XCTAssertEqual(keys, ["song_name", "artist", "isrc", "duration"])
    }

    // MARK: - Session handling

    func testBypassTokenGoesInTheQueryAndSkipsTheChallenge() async throws {
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track())

        let request = try XCTUnwrap(RythmStub.requests.first)
        XCTAssertEqual(Self.queryValue("bypass_token", in: request), "test-bypass")
        // A bypass and a bearer are alternatives; sending both would be a lie
        // about which credential the request is relying on.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testWithoutABypassTheSolvedSessionIsSentAsABearer() async throws {
        PlaybackSourceSettings.rythmBypassToken = ""
        var solves: [Bool] = []
        RythmPlaybackService.sessionTokenProvider = { _, force in
            solves.append(force)
            return "session-abc"
        }
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track())

        let request = try XCTUnwrap(RythmStub.requests.first)
        // `invalid_authorization_header` is what a bare token earns.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-abc")
        XCTAssertNil(Self.queryValue("bypass_token", in: request))
        XCTAssertEqual(solves, [false])
    }

    func testSolveIsAskedForTheConfiguredBaseURL() async throws {
        PlaybackSourceSettings.rythmBypassToken = ""
        PlaybackSourceSettings.rythmBaseURL = "https://staging.example/"
        var seen: [String] = []
        RythmPlaybackService.sessionTokenProvider = { base, _ in
            seen.append(base)
            return "session-abc"
        }
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track())
        XCTAssertEqual(seen, ["https://staging.example"])
    }

    func testAFailedSolveSurfacesRatherThanCallingPlayback() async {
        PlaybackSourceSettings.rythmBypassToken = ""
        RythmPlaybackService.sessionTokenProvider = { _, _ in
            throw ServiceError.unavailable("Turnstile needs an active window")
        }
        await assertFails(Self.track(), matching: "Turnstile needs an active window")
        XCTAssertTrue(RythmStub.requests.isEmpty)
    }

    func testExpiredSessionIsResolvedOnceWithAFreshToken() async throws {
        PlaybackSourceSettings.rythmBypassToken = ""
        var solves: [Bool] = []
        RythmPlaybackService.sessionTokenProvider = { _, force in
            solves.append(force)
            return force ? "session-fresh" : "session-stale"
        }
        RythmStub.enqueue(status: 401, body: #"{"detail":{"code":"session_required"}}"#)
        RythmStub.enqueue(ok: Self.playbackBody())

        let stream = try await resolve(Self.track())
        XCTAssertEqual(stream.provider, .rythm)
        XCTAssertEqual(solves, [false, true])
        XCTAssertEqual(RythmStub.requests.count, 2)
        XCTAssertEqual(RythmStub.requests.last?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer session-fresh")
    }

    func testInvalidSessionIsRetriedTheSameWay() async throws {
        PlaybackSourceSettings.rythmBypassToken = ""
        RythmPlaybackService.sessionTokenProvider = { _, force in force ? "fresh" : "stale" }
        RythmStub.enqueue(status: 401, body: #"{"detail":{"code":"invalid_session"}}"#)
        RythmStub.enqueue(ok: Self.playbackBody())

        _ = try await resolve(Self.track())
        XCTAssertEqual(RythmStub.requests.count, 2)
    }

    func testForbiddenIsRetriedTheSameWay() async throws {
        PlaybackSourceSettings.rythmBypassToken = ""
        RythmPlaybackService.sessionTokenProvider = { _, force in force ? "fresh" : "stale" }
        RythmStub.enqueue(status: 403, body: #"{"detail":{"code":"session_expired"}}"#)
        RythmStub.enqueue(ok: Self.playbackBody())

        _ = try await resolve(Self.track())
        XCTAssertEqual(RythmStub.requests.count, 2)
    }

    func testARejectedBypassFallsBackToSolvingTheChallenge() async throws {
        // A stale bypass token otherwise dead-ends the leg: the first call has no
        // bearer to refresh, so the retry has to switch credential kinds.
        var solves: [Bool] = []
        RythmPlaybackService.sessionTokenProvider = { _, force in
            solves.append(force)
            return "session-fresh"
        }
        RythmStub.enqueue(status: 401, body: #"{"detail":{"code":"session_required"}}"#)
        RythmStub.enqueue(ok: Self.playbackBody())

        _ = try await resolve(Self.track())
        XCTAssertEqual(solves, [true])
        let retry = try XCTUnwrap(RythmStub.requests.last)
        XCTAssertEqual(retry.value(forHTTPHeaderField: "Authorization"), "Bearer session-fresh")
        // The rejected bypass must not ride along on the retry.
        XCTAssertNil(Self.queryValue("bypass_token", in: retry))
    }

    func testTheSessionRetryHappensAtMostOnce() async {
        PlaybackSourceSettings.rythmBypassToken = ""
        RythmPlaybackService.sessionTokenProvider = { _, _ in "session" }
        RythmStub.enqueue(status: 401, body: #"{"detail":{"code":"session_required"}}"#)
        RythmStub.enqueue(status: 401, body: #"{"detail":{"code":"session_required"}}"#)
        RythmStub.enqueue(ok: Self.playbackBody())

        await assertFails(Self.track(), matching: "HTTP 401")
        XCTAssertEqual(RythmStub.requests.count, 2)
    }

    func testAFailedResolveDuringTheRetrySurfaces() async {
        PlaybackSourceSettings.rythmBypassToken = ""
        RythmPlaybackService.sessionTokenProvider = { _, force in
            if force { throw ServiceError.unavailable("Rythm Turnstile: turnstile_failed") }
            return "stale"
        }
        RythmStub.enqueue(status: 401, body: #"{"detail":{"code":"session_required"}}"#)

        await assertFails(Self.track(), matching: "turnstile_failed")
        XCTAssertEqual(RythmStub.requests.count, 1)
    }

    // MARK: - Failure reporting

    func testUpstreamDetailIsNamedSoTheChainErrorSaysWhichLegGaveUp() async {
        RythmStub.enqueue(status: 502, body: #"{"detail":{"code":"upstream_unavailable"}}"#)
        await assertFails(Self.track(), matching: "Rythm: upstream_unavailable")
    }

    func testNoMatchIsSurfacedVerbatim() async {
        RythmStub.enqueue(status: 404, body: #"{"detail":"No match found"}"#)
        await assertFails(Self.track(), matching: "Rythm: No match found")
    }

    func testStatusOnlyFailureFallsBackToTheCode() async {
        RythmStub.enqueue(status: 500, body: "<!doctype html><html>oops</html>")
        await assertFails(Self.track(), matching: "HTTP 500")
    }

    func testSchemaRejectionReportsTheValidationDetail() async {
        // FastAPI answers a schema violation with `detail` as an *array*, unlike
        // every other error this endpoint produces.
        RythmStub.enqueue(status: 422, body: """
        {"detail":[{"type":"string_too_short","loc":["body","song_name"],\
        "msg":"String should have at least 1 character","input":""}]}
        """)
        await assertFails(Self.track(), matching: "String should have at least 1 character")
    }

    func testTimeoutNamesTheLegAndTheHost() async {
        RythmStub.enqueue(error: URLError(.timedOut))
        await assertFails(Self.track(), matching: "timed out at https://track-api.monochrome.tf")
    }

    func testTransportFailureIsNotSwallowed() async {
        RythmStub.enqueue(error: URLError(.notConnectedToInternet))
        do {
            _ = try await resolve(Self.track())
            XCTFail("expected a failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Response decoding

    func testResolvedStreamIsTaggedAsRythm() async throws {
        RythmStub.enqueue(ok: Self.playbackBody(url: "https://cdn.example/audio/track.flac"))
        let stream = try await resolve(Self.track())

        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example/audio/track.flac")
        XCTAssertEqual(stream.provider, .rythm)
        XCTAssertFalse(stream.isPreview)
        XCTAssertNil(stream.previewReason)
        XCTAssertNil(stream.replayGain)
        XCTAssertNil(stream.peak)
    }

    func testResolvedStreamCarriesNoMonochromeOriginHeaders() async throws {
        // The URL points at whichever upstream CDN Rythm resolved. Those sign
        // their own requests, so a foreign Origin is at best ignored and at worst
        // a 403 on the media GET.
        RythmStub.enqueue(ok: Self.playbackBody())
        let stream = try await resolve(Self.track())
        XCTAssertTrue(stream.requestHeaders.isEmpty)
    }

    func testQualityBadgeIsReadOffTheResolvedURL() async throws {
        let expected = [
            "https://cdn.example/a.flac": "FLAC",
            "https://cdn.example/a.mp3": "MP3",
            "https://cdn.example/a.m4a": "AAC",
            "https://cdn.example/a.opus": "OPUS",
        ]
        for (url, token) in expected {
            RythmStub.reset()
            RythmStub.enqueue(ok: Self.playbackBody(url: url))
            let stream = try await resolve(Self.track())
            XCTAssertEqual(stream.quality, token, url)
        }
    }

    func testQualityBadgeIgnoresTheRequestedTier() async throws {
        // The user's preference is a request, not a fact about what came back.
        RythmStub.enqueue(ok: Self.playbackBody(url: "https://cdn.example/a.mp3"))
        let stream = try await resolve(Self.track(), quality: .hiResLossless)
        XCTAssertEqual(stream.quality, "MP3")
    }

    func testQualityFallsBackToTheCatalogClaimForOpaqueURLs() async throws {
        // Signed CDN URLs routinely have no extension to read.
        RythmStub.enqueue(ok: Self.playbackBody(url: "https://cdn.example/stream?id=1&exp=2"))
        let stream = try await resolve(Self.track(mediaTags: ["HIRES_LOSSLESS"]))
        XCTAssertEqual(stream.quality, PlaybackQuality.hiResLossless.rawValue)
    }

    func testQualityIsUnknownRatherThanInventedWhenNothingSaysOtherwise() async throws {
        RythmStub.enqueue(ok: Self.playbackBody(url: "https://cdn.example/stream?id=1"))
        let stream = try await resolve(Self.track())
        XCTAssertEqual(stream.quality, "UNKNOWN")
    }

    func testReportedDurationWinsOverTheCatalogDuration() async throws {
        RythmStub.enqueue(ok: Self.playbackBody(durationSeconds: 194.5))
        let stream = try await resolve(Self.track(duration: 191))
        XCTAssertEqual(stream.mediaDuration, 194.5)
    }

    func testCatalogDurationIsKeptWhenTheResolverOmitsOne() async throws {
        RythmStub.enqueue(ok: Self.playbackBody(durationSeconds: nil))
        let stream = try await resolve(Self.track(duration: 191))
        XCTAssertEqual(stream.mediaDuration, 191)
    }

    func testDurationStaysNilWhenNeitherSideKnowsIt() async throws {
        RythmStub.enqueue(ok: Self.playbackBody(durationSeconds: nil))
        let stream = try await resolve(Self.track(duration: 0))
        XCTAssertNil(stream.mediaDuration)
    }

    func testMissingURLIsReportedAsAnUnresolvedTrack() async {
        RythmStub.enqueue(ok: #"{"track_id":"1","recording_id":"2","title":"t","artists":["a"]}"#)
        await assertFails(Self.track(), matching: "Rythm returned no stream URL")
    }

    func testUnparseableBodyIsReportedAsAnUnresolvedTrack() async {
        RythmStub.enqueue(ok: "not json at all")
        await assertFails(Self.track(), matching: "Rythm returned no stream URL")
    }

    func testUnusableURLIsReportedAsAnUnresolvedTrack() async {
        RythmStub.enqueue(ok: #"{"url":"","track_id":"1","recording_id":"2","title":"t","artists":[]}"#)
        await assertFails(Self.track(), matching: "Rythm returned no stream URL")
    }

    func testResponseIsNotServedFromTheURLCache() async throws {
        // Resolved URLs are short-lived and signed; a cached one plays once and
        // then 403s for the rest of the session.
        RythmStub.enqueue(ok: Self.playbackBody())
        _ = try await resolve(Self.track())
        XCTAssertEqual(RythmStub.requests.first?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    // MARK: - Launch prewarm

    func testPrewarmSolvesRythmWithRythmsOwnSiteKeyAndAction() throws {
        PlaybackSourceSettings.amazonTurnstileSiteKey = "0xAMAZON"
        PlaybackSourceSettings.rythmTurnstileSiteKey = "0xRYTHM"
        let target = try XCTUnwrap(AmazonTurnstileAuth.prewarmTarget())
        XCTAssertEqual(target.exchange.id, "rythm")
        XCTAssertEqual(target.siteKey, "0xRYTHM")
        XCTAssertEqual(target.action, "auth")
        XCTAssertEqual(target.base, "https://track-api.monochrome.tf")
    }

    func testPrewarmFallsBackToAmazonWhenRythmIsOff() throws {
        PlaybackSourceSettings.rythmEnabled = false
        PlaybackSourceSettings.amazonTurnstileSiteKey = "0xAMAZON"
        let target = try XCTUnwrap(AmazonTurnstileAuth.prewarmTarget())
        XCTAssertEqual(target.exchange.id, "amazon")
        XCTAssertEqual(target.siteKey, "0xAMAZON")
        // Amazon's exchange does not check the action; sending one it does not
        // expect is the same failure in the other direction.
        XCTAssertEqual(target.action, "")
    }

    // MARK: - Turnstile action

    func testRythmDefaultsToTheActionTheResolverPublishes() {
        // `GET /config` reports `"turnstile_action":"auth"`, and the exchange
        // rejects a token solved without it as "turnstile action mismatch".
        XCTAssertEqual(PlaybackSourceSettings.rythmTurnstileAction, "auth")
    }

    func testChallengeRendersTheActionForBothChallengeModes() {
        for mode in [AmazonTurnstileAuth.ChallengeMode.interactionOnly, .alwaysVisible] {
            let html = AmazonTurnstileAuth.challengeHTML(siteKey: "0xTEST", mode: mode, action: "auth")
            XCTAssertTrue(html.contains("action: 'auth',"), "\(mode)")
        }
    }

    func testChallengeOmitsTheActionEntirelyWhenThereIsNone() {
        // An empty `action: ''` is not the same as no action — Amazon accepts a
        // token with neither, and would reject one carrying an empty string.
        let html = AmazonTurnstileAuth.challengeHTML(siteKey: "0xTEST", mode: .interactionOnly, action: "")
        XCTAssertFalse(html.contains("action:"))
    }

    func testChallengeActionIsEscapedLikeTheSiteKey() {
        let html = AmazonTurnstileAuth.challengeHTML(
            siteKey: "0xTEST", mode: .interactionOnly, action: "a'\\b"
        )
        XCTAssertTrue(html.contains("action: 'a\\'\\\\b',"))
    }

    func testRythmActionIsConfigurable() {
        PlaybackSourceSettings.rythmTurnstileAction = "playback"
        XCTAssertEqual(PlaybackSourceSettings.rythmTurnstileAction, "playback")
        XCTAssertEqual(AmazonTurnstileAuth.prewarmTarget()?.action, "playback")
    }

    func testPrewarmDoesNothingWhenBothGatedLegsAreOff() {
        PlaybackSourceSettings.rythmEnabled = false
        PlaybackSourceSettings.amazonEnabled = false
        XCTAssertNil(AmazonTurnstileAuth.prewarmTarget())
    }

    // MARK: - Helpers

    private func resolve(
        _ track: Track,
        quality: PlaybackQuality = .lossless
    ) async throws -> StreamResponse {
        try await RythmPlaybackService.resolveStream(for: track, quality: quality, session: session)
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
        duration: Double = 191,
        isrc: String? = nil,
        mediaTags: [String]? = nil
    ) -> Track {
        Track(id: "tidal:447580805", title: title,
              artist: Artist(id: "3523908", name: artist),
              duration: duration, mediaTags: mediaTags, isrc: isrc)
    }

    private static func playbackBody(
        url: String = "https://cdn.example/audio/track.flac",
        durationSeconds: Double? = 194.5
    ) -> String {
        var object: [String: Any] = [
            "url": url,
            "track_id": "12345",
            "recording_id": "b1a9c0de-0000-4000-8000-000000000000",
            "title": "Ghosts 'n' Stuff",
            "artists": ["deadmau5", "Rob Swire"],
            "isrc": "GBTDG0900132",
        ]
        if let durationSeconds { object["duration_seconds"] = durationSeconds }
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
final class RythmStub: URLProtocol {
    struct Response {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
    }

    private static let lock = NSLock()
    private static var queue: [Response] = []
    private static var seen: [(URLRequest, Data?)] = []

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
        return seen.map(\.0)
    }

    /// Decoded JSON bodies, in the order they were sent.
    static var bodies: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return seen.compactMap { _, data in
            guard let data else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands the body over as a stream, so `httpBody` is nil here.
        let body = Self.drain(request)
        Self.lock.lock()
        Self.seen.append((request, body))
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

    private static func drain(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
