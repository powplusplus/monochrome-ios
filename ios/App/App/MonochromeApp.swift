import SwiftUI

@main
struct MonochromeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var playback = PlaybackEngine.shared
    @StateObject private var library = LibraryRepository.shared
    @StateObject private var auth = AuthSession.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var parties = PartyService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(playback)
                .environmentObject(library)
                .environmentObject(auth)
                .environmentObject(downloads)
                .environmentObject(parties)
                .onOpenURL { auth.handle($0) }
                .onChange(of: scenePhase) { phase in
                    // Warm stream resolution on every return to foreground so the
                    // first tap plays on already-resolved bytes instead of a cold hop.
                    if phase == .active { playback.warmForeground() }
                }
                .task {
                    // Both of these exist to move work off the first play: refresh
                    // the instance pool before the first search runs against it,
                    // and solve Amazon's Cloudflare gate while the user browses.
                    await InstanceDirectory.shared.refreshIfStale()
                    AmazonTurnstileAuth.shared.prewarm()
                    // `isSignedIn` only flips once the profile call comes
                    // back, so gating the sync on it skipped the pull on every
                    // cold launch — the playlists were on the server, the app
                    // just never asked. `syncWithCloud` already no-ops without a
                    // stored bearer, so let it make that call itself.
                    await library.syncWithCloud()
                }
        }
    }
}
