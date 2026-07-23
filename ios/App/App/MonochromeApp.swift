import SwiftUI

@main
struct MonochromeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var playback = PlaybackEngine.shared
    @StateObject private var library = LibraryRepository.shared
    @StateObject private var auth = AuthSession.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var parties = PartyService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(playback)
                .environmentObject(library)
                .environmentObject(auth)
                .environmentObject(downloads)
                .environmentObject(parties)
                .onOpenURL { auth.handle($0) }
                .task {
                    library.migrateLegacyIfNeeded()
                    // Both of these exist to move work off the first play: refresh
                    // the instance pool before the first search runs against it,
                    // and solve Amazon's Cloudflare gate while the user browses.
                    await InstanceDirectory.shared.refreshIfStale()
                    AmazonTurnstileAuth.shared.prewarm()
                    if auth.isSignedIn { await library.syncWithCloud() }
                }
        }
    }
}
