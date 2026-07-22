import AVFoundation
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch { print("[AudioSession] \(error.localizedDescription)") }
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChange(_:)), name: AVAudioSession.routeChangeNotification, object: session)
        return true
    }

    @objc private func interruption(_ notification: Notification) {
        Task { @MainActor in PlaybackEngine.shared.handleInterruption(notification) }
    }

    @objc private func routeChange(_ notification: Notification) {
        Task { @MainActor in PlaybackEngine.shared.handleRouteChange(notification) }
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Task { @MainActor in AuthSession.shared.handle(url) }
        return url.scheme == "monochrome"
    }
}
