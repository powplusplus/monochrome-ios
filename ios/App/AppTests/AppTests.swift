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
}
