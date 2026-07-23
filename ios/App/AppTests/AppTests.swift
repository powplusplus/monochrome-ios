import XCTest
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

    func testAmazonTurnstileChallengeHTMLInvisibleParity() {
        let html = AmazonTurnstileAuth.challengeHTML(siteKey: "0xTEST", mode: .invisible)
        XCTAssertTrue(html.contains("execution: 'execute'"))
        XCTAssertTrue(html.contains("size: 'invisible'"))
        XCTAssertTrue(html.contains("before-interactive-callback"))
        XCTAssertTrue(html.contains("turnstile.execute(id)"))
        XCTAssertTrue(html.contains("sitekey: '0xTEST'"))
        XCTAssertFalse(html.contains("appearance: 'interaction-only'"))
        XCTAssertFalse(html.contains("appearance: 'always'"))
    }

    func testProviderRequestsUseOfficialMonochromeOrigin() {
        XCTAssertEqual(MusicService.webRequestHeaders["Origin"], "https://monochrome.tf")
        XCTAssertEqual(MusicService.webRequestHeaders["Referer"], "https://monochrome.tf/")
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
        let html = AmazonTurnstileAuth.challengeHTML(siteKey: "key'\\x", mode: .invisible)
        XCTAssertTrue(html.contains("sitekey: 'key\\'\\\\x'"))
    }
}
