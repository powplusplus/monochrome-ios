import XCTest
import Foundation
@testable import App

final class AppTests: XCTestCase {
    func testTrackMappingAcceptsProductionShape() throws {
        let payload: [String: Any] = [
            "id": 123, "title": "Native Song", "duration": 245,
            "artist": ["id": 7, "name": "Artist"],
            "album": ["id": 9, "title": "Album", "cover": "01234567-89ab-cdef-0123-456789abcdef"]
        ]
        let track = try XCTUnwrap(ModelMapper.track(payload))
        XCTAssertEqual(track.id, "tidal:123")
        XCTAssertEqual(track.artist.name, "Artist")
        XCTAssertEqual(track.duration, 245)
        XCTAssertNotNil(track.artworkURL)
    }

    func testTrackMappingAcceptsOpenAPISearchDuration() throws {
        let payload: [String: Any] = [
            "id": 447580805,
            "title": "Ghosts 'n' Stuff",
            "duration": "PT3M11S",
            "isrc": "GBTDG0900132",
            "artist": ["id": 3523908, "name": "deadmau5"],
        ]

        let track = try XCTUnwrap(ModelMapper.track(payload))
        XCTAssertEqual(track.duration, 191)
        XCTAssertEqual(track.isrc, "GBTDG0900132")
    }

    func testTrackMappingAcceptsFractionalOpenAPIDuration() throws {
        let track = try XCTUnwrap(ModelMapper.track([
            "id": 1, "title": "Song", "artist": "Artist", "duration": "PT1H2M3.5S",
        ]))
        XCTAssertEqual(track.duration, 3_723.5)
    }

    func testProviderPrefixIsPreserved() throws {
        let track = try XCTUnwrap(ModelMapper.track(["id": "qobuz:42", "title": "Song", "artist": "Artist"]))
        XCTAssertEqual(track.provider, .qobuz)
        XCTAssertEqual(track.playbackID, "42")
    }

    @MainActor
    func testOAuthURLDecodesProductionResponseShapes() throws {
        let direct = AuthSession.oauthURL(from: ["url": "https://accounts.google.com/o/oauth2/auth"])
        let nested = AuthSession.oauthURL(from: ["data": ["redirectURL": "https://github.com/login/oauth/authorize"]])
        XCTAssertEqual(direct?.host, "accounts.google.com")
        XCTAssertEqual(nested?.host, "github.com")
        XCTAssertNil(AuthSession.oauthURL(from: ["url": "monochrome://auth-callback?secret=unsafe-to-open-here"]))
    }

    @MainActor
    func testLibraryPersistsFavoritesInMemory() {
        let repository = LibraryRepository(inMemory: true)
        let track = Track(id: "tidal:1", title: "Song", artist: Artist(id: "1", name: "Artist"))
        repository.toggleFavorite(track)
        XCTAssertTrue(repository.isFavorite(track))
        repository.toggleFavorite(track)
        XCTAssertFalse(repository.isFavorite(track))
    }

    @MainActor
    func testAmazonTurnstileJwtCacheRoundTrip() {
        let auth = AmazonTurnstileAuth.shared
        auth.clearCache()
        XCTAssertNil(auth.cachedJWT())

        let expiry = Date().timeIntervalSince1970 * 1000 + 60 * 60 * 1000
        UserDefaults.standard.set("native-jwt", forKey: "native.amazonTurnstileJwt")
        UserDefaults.standard.set(expiry, forKey: "native.amazonTurnstileExpiry")
        XCTAssertEqual(auth.cachedJWT(), "native-jwt")

        auth.clearCache()
        XCTAssertNil(auth.cachedJWT())
    }

    @MainActor
    func testAmazonTurnstileJwtCacheRejectsExpired() {
        let auth = AmazonTurnstileAuth.shared
        UserDefaults.standard.set("stale-jwt", forKey: "native.amazonTurnstileJwt")
        UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000 - 1000, forKey: "native.amazonTurnstileExpiry")
        XCTAssertNil(auth.cachedJWT())
        auth.clearCache()
    }

    @MainActor
    func testTurnstileSessionCachesAreIsolatedPerExchange() {
        let auth = AmazonTurnstileAuth.shared
        auth.clearCache(for: .amazon)
        auth.clearCache(for: .rythm)

        // Cloudflare tokens are single-use, so each exchange holds its own
        // session. Sharing one slot would let an Amazon JWT be sent to Rythm.
        let expiry = Date().timeIntervalSince1970 * 1000 + 60 * 60 * 1000
        UserDefaults.standard.set("rythm-session", forKey: AmazonTurnstileAuth.Exchange.rythm.tokenKey)
        UserDefaults.standard.set(expiry, forKey: AmazonTurnstileAuth.Exchange.rythm.expiryKey)

        XCTAssertEqual(auth.cachedJWT(for: .rythm), "rythm-session")
        XCTAssertNil(auth.cachedJWT(for: .amazon))

        auth.clearCache(for: .rythm)
        XCTAssertNil(auth.cachedJWT(for: .rythm))
    }

    func testRythmExchangeMatchesResolverContract() {
        let rythm = AmazonTurnstileAuth.Exchange.rythm
        XCTAssertEqual(rythm.path, "/auth/turnstile")
        XCTAssertEqual(rythm.tokenField, "turnstile_token")
        XCTAssertNotEqual(rythm.tokenKey, AmazonTurnstileAuth.Exchange.amazon.tokenKey)
        XCTAssertEqual(AmazonTurnstileAuth.Exchange.amazon.path, "/api/auth/turnstile")
        XCTAssertEqual(AmazonTurnstileAuth.Exchange.amazon.tokenField, "cf_turnstile_response")
    }

    func testTurnstileExchangeErrorDetailReadsBothProviderShapes() {
        let rythm = Data(#"{"detail":{"code":"turnstile_failed","errors":["invalid-input-response"]}}"#.utf8)
        XCTAssertEqual(
            AmazonTurnstileAuth.exchangeErrorDetail(in: rythm),
            "turnstile_failed (invalid-input-response)"
        )
        let session = Data(#"{"detail":{"code":"session_required"}}"#.utf8)
        XCTAssertEqual(AmazonTurnstileAuth.exchangeErrorDetail(in: session), "session_required")
        let amazon = Data(#"{"error":"turnstile_required","message":"Missing X-Turnstile-JWT header."}"#.utf8)
        XCTAssertEqual(AmazonTurnstileAuth.exchangeErrorDetail(in: amazon), "turnstile_required")
        XCTAssertNil(AmazonTurnstileAuth.exchangeErrorDetail(in: Data("<!doctype html>".utf8)))
    }

    func testRythmIsAStreamResolverNotACatalogProvider() {
        XCTAssertFalse(Provider.musicCases.contains(.rythm))
        XCTAssertFalse(Provider.musicCases.contains(.podcast))
        XCTAssertTrue(Provider.musicCases.contains(.tidal))
        // Persisted stream responses decode by raw value — keep it stable.
        XCTAssertEqual(Provider.rythm.rawValue, "rythm")
    }

    func testAmazonTurnstileChallengeHTMLInteractionOnlyParity() {
        let html = AmazonTurnstileAuth.challengeHTML(siteKey: "0xTEST", mode: .interactionOnly)
        XCTAssertTrue(html.contains("execution: 'execute'"))
        XCTAssertTrue(html.contains("appearance: 'interaction-only'"))
        XCTAssertTrue(html.contains("before-interactive-callback"))
        XCTAssertTrue(html.contains("turnstile.execute(id)"))
        XCTAssertTrue(html.contains("sitekey: '0xTEST'"))
        XCTAssertFalse(html.contains("appearance: 'always'"))
    }

    func testProviderRequestsUseOfficialMonochromeOrigin() {
        XCTAssertEqual(MusicService.webRequestHeaders["Origin"], "https://monochrome.tf")
        XCTAssertEqual(MusicService.webRequestHeaders["Referer"], "https://monochrome.tf/")
    }

    func testPlaybackRetryClassifiesGatewayAndSignedURLFailuresAsTransient() {
        for status in [403, 404, 408, 409, 425, 429, 500, 502, 503, 504] {
            XCTAssertTrue(MusicService.isTransientPlaybackError(ServiceError.http(status)), "HTTP \(status)")
        }
        XCTAssertFalse(MusicService.isTransientPlaybackError(ServiceError.http(400)))
        XCTAssertFalse(MusicService.isTransientPlaybackError(ServiceError.http(422)))
        XCTAssertFalse(MusicService.isTransientPlaybackError(ServiceError.unavailable("track is not in the catalog")))
    }

    func testPlaybackRetryClassifiesConnectionFailuresAsTransient() {
        for code in [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost,
                     .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable] {
            XCTAssertTrue(MusicService.isTransientPlaybackError(URLError(code)), "\(code)")
        }
        XCTAssertFalse(MusicService.isTransientPlaybackError(URLError(.badURL)))
    }

    func testAmazonTurnstileChallengeHTMLVisibleFallbackParity() {
        let html = AmazonTurnstileAuth.challengeHTML(siteKey: "0xTEST", mode: .alwaysVisible)
        XCTAssertTrue(html.contains("execution: 'render'"))
        XCTAssertTrue(html.contains("appearance: 'always'"))
        XCTAssertTrue(html.contains("size: 'compact'"))
        XCTAssertFalse(html.contains("turnstile.execute"))
        XCTAssertFalse(html.contains("interaction-only"))
    }

    func testAmazonTurnstileSiteKeyEscapesQuotes() {
        let html = AmazonTurnstileAuth.challengeHTML(siteKey: "key'\\x", mode: .interactionOnly)
        XCTAssertTrue(html.contains("sitekey: 'key\\'\\\\x'"))
    }

    func testAmazonTurnstileExpiryUsesJwtExpClaim() {
        let exp = Date().timeIntervalSince1970 + 600
        let jwt = Self.unsignedJWT(claims: ["exp": exp])
        // Retired a minute before the server stops honouring it.
        XCTAssertEqual(AmazonTurnstileAuth.expiryMilliseconds(forJWT: jwt), (exp - 60) * 1000, accuracy: 1)
    }

    func testAmazonTurnstileExpiryFallsBackWhenClaimUnreadable() {
        let floor = Date().timeIntervalSince1970 * 1000 + 54 * 60 * 1000
        for jwt in ["", "not-a-jwt", "a.!!!.c", Self.unsignedJWT(claims: ["sub": "no-exp"])] {
            XCTAssertGreaterThan(AmazonTurnstileAuth.expiryMilliseconds(forJWT: jwt), floor)
        }
    }

    func testInstanceDirectoryNormalizesDocumentEntries() {
        // Shapes taken from the live instances.json: a trailing slash on some
        // entries, which `json(path:)` would otherwise turn into `host//search/`.
        let normalized = InstanceDirectory.normalize([
            "https://api.monochrome.tf/",
            "  https://wolf.qqdl.site  ",
            "https://hifi.p1nkhamster.xyz/",
        ])
        XCTAssertEqual(normalized, [
            "https://api.monochrome.tf",
            "https://wolf.qqdl.site",
            "https://hifi.p1nkhamster.xyz",
        ])
    }

    func testInstanceDirectoryDropsJunkAndDuplicates() {
        let normalized = InstanceDirectory.normalize([
            "https://wolf.qqdl.site",
            "https://wolf.qqdl.site/",   // same host once the slash is trimmed
            "",
            "not a url",
            "ftp://wolf.qqdl.site",      // only http(s) is fetchable here
            "https://maus.qqdl.site",
        ])
        XCTAssertEqual(normalized, ["https://wolf.qqdl.site", "https://maus.qqdl.site"])
    }

    /// Header/payload/signature shaped like a real token; only the payload is read.
    private static func unsignedJWT(claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
