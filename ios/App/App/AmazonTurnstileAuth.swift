import Foundation
import UIKit
import WebKit

/// Mirrors web Monochrome `getTurnstileJwt`: solve Cloudflare Turnstile on
/// `monochrome.tf` origin, exchange token at Amazon `/api/auth/turnstile`.
///
/// Invisible / interaction-only first (no UI flash). Overlay only when CF needs
/// a click, or when the invisible attempt fails and we fall back to compact.
@MainActor
final class AmazonTurnstileAuth: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AmazonTurnstileAuth()

    enum ChallengeMode: String {
        /// Web parity: `execution: execute` + `appearance: interaction-only`.
        case interactionOnly
        /// Visible compact fallback after invisible failure.
        case alwaysVisible
    }

    private let jwtKey = "native.amazonTurnstileJwt"
    private let expiryKey = "native.amazonTurnstileExpiry"
    private var webView: WKWebView?
    private var hostWindow: UIWindow?
    private var overlay: TurnstileOverlayViewController?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutItem: DispatchWorkItem?
    private var inFlight: Task<String, Error>?
    private var mode: ChallengeMode = .interactionOnly
    private var siteKeyForRetry: String = ""

    func cachedJWT() -> String? {
        let jwt = UserDefaults.standard.string(forKey: jwtKey) ?? ""
        let expiry = UserDefaults.standard.double(forKey: expiryKey)
        guard !jwt.isEmpty, Date().timeIntervalSince1970 * 1000 < expiry else { return nil }
        return jwt
    }

    func clearCache() {
        UserDefaults.standard.removeObject(forKey: jwtKey)
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }

    func accessToken(
        apiBaseURL: String,
        siteKey: String = PlaybackSourceSettings.amazonTurnstileSiteKey,
        forceRefresh: Bool = false
    ) async throws -> String {
        if !forceRefresh, let cached = cachedJWT() { return cached }
        if let inFlight, !forceRefresh { return try await inFlight.value }

        let task = Task<String, Error> {
            if forceRefresh { clearCache() }
            let turnstileToken = try await solveTurnstile(siteKey: siteKey)
            let base = apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/api/auth/turnstile") else {
                throw ServiceError.invalidResponse
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "cf_turnstile_response": turnstileToken
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let jwt = object?["access_token"] as? String, !jwt.isEmpty else {
                throw ServiceError.malformed("Amazon Turnstile JWT")
            }
            let expiry = Date().timeIntervalSince1970 * 1000 + 60 * 60 * 1000
            UserDefaults.standard.set(jwt, forKey: jwtKey)
            UserDefaults.standard.set(expiry, forKey: expiryKey)
            return jwt
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// HTML loaded into WKWebView. Exposed for unit tests.
    static func challengeHTML(siteKey: String, mode: ChallengeMode) -> String {
        let escapedKey = siteKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let renderOptions: String
        switch mode {
        case .interactionOnly:
            renderOptions = """
                  sitekey: '\(escapedKey)',
                  execution: 'execute',
                  appearance: 'interaction-only',
                  theme: 'dark',
                  'before-interactive-callback': function() {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ interactive: true });
                  },
                  callback: function(token) {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: true, token: token });
                  },
                  'error-callback': function() {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: false, error: 'turnstile_failed' });
                  },
                  'expired-callback': function() {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: false, error: 'turnstile_expired' });
                  }
            """
        case .alwaysVisible:
            renderOptions = """
                  sitekey: '\(escapedKey)',
                  size: 'compact',
                  execution: 'render',
                  appearance: 'always',
                  theme: 'dark',
                  callback: function(token) {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: true, token: token });
                  },
                  'error-callback': function() {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: false, error: 'turnstile_failed' });
                  },
                  'expired-callback': function() {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: false, error: 'turnstile_expired' });
                  }
            """
        }
        let executeLine = mode == .interactionOnly
            ? "var id = turnstile.render('#cf', opts); turnstile.execute(id);"
            : "turnstile.render('#cf', opts);"
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
          html,body{margin:0;padding:0;background:transparent;display:flex;align-items:center;justify-content:center;min-height:100%;}
          #cf{min-height:70px;}
        </style>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer></script>
        </head><body>
        <div id="cf"></div>
        <script>
        function boot() {
          if (!window.turnstile) { setTimeout(boot, 40); return; }
          try {
            var opts = {
        \(renderOptions)
            };
            \(executeLine)
          } catch (e) {
            window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: false, error: String(e) });
          }
        }
        boot();
        </script>
        </body></html>
        """
    }

    private func solveTurnstile(siteKey: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.finishPending(with: .failure(CancellationError()))
            self.continuation = continuation
            self.siteKeyForRetry = siteKey
            self.mode = .interactionOnly

            guard Self.foregroundWindowScene != nil else {
                self.continuation = nil
                continuation.resume(throwing: ServiceError.unavailable("Amazon Turnstile needs an active window"))
                return
            }

            presentChallenge(siteKey: siteKey, mode: .interactionOnly, showOverlay: false)

            let timeout = DispatchWorkItem { [weak self] in
                self?.finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile timed out")))
            }
            timeoutItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        }
    }

    private func presentChallenge(siteKey: String, mode: ChallengeMode, showOverlay: Bool) {
        tearDownWebViewOnly()

        guard let scene = Self.foregroundWindowScene else {
            finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile needs an active window")))
            return
        }

        self.mode = mode

        let controller = WKUserContentController()
        controller.add(self, name: "monochromeTurnstile")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        self.webView = webView

        let overlay = TurnstileOverlayViewController(webView: webView) { [weak self] in
            self?.finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile cancelled")))
        }
        self.overlay = overlay

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = overlay
        // Keep window in hierarchy for invisible attempt, but hidden until interactive / fallback.
        window.isHidden = !showOverlay
        if showOverlay {
            window.makeKeyAndVisible()
            overlay.setChromeVisible(true)
        } else {
            // Still attach so WKWebView runs scripts; zero-size / alpha avoids flash.
            window.alpha = 0.01
            window.isUserInteractionEnabled = false
            window.makeKeyAndVisible()
            overlay.setChromeVisible(false)
        }
        self.hostWindow = window

        // baseURL must be an allowlisted Monochrome host so Turnstile accepts the site key.
        webView.loadHTMLString(Self.challengeHTML(siteKey: siteKey, mode: mode), baseURL: URL(string: "https://monochrome.tf/"))
    }

    private func revealOverlay() {
        guard let window = hostWindow, let overlay else { return }
        window.alpha = 1
        window.isUserInteractionEnabled = true
        window.isHidden = false
        window.makeKeyAndVisible()
        overlay.setChromeVisible(true)
    }

    private func retryVisibleFallback() {
        guard mode == .interactionOnly else {
            finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile: turnstile_failed")))
            return
        }
        presentChallenge(siteKey: siteKeyForRetry, mode: .alwaysVisible, showOverlay: true)
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard message.name == "monochromeTurnstile" else { return }
            guard let body = message.body as? [String: Any] else {
                finishPending(with: .failure(ServiceError.malformed("Turnstile message")))
                return
            }
            if body["interactive"] as? Bool == true {
                revealOverlay()
                return
            }
            if body["ok"] as? Bool == true, let token = body["token"] as? String, !token.isEmpty {
                finishPending(with: .success(token))
            } else {
                let detail = body["error"] as? String ?? "turnstile_failed"
                if detail == "turnstile_failed", mode == .interactionOnly {
                    retryVisibleFallback()
                    return
                }
                finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile: \(detail)")))
            }
        }
    }

    private func tearDownWebViewOnly() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "monochromeTurnstile")
        webView?.removeFromSuperview()
        webView = nil
        overlay = nil
        hostWindow?.isHidden = true
        hostWindow?.rootViewController = nil
        hostWindow = nil
    }

    private func finishPending(with result: Result<String, Error>) {
        timeoutItem?.cancel()
        timeoutItem = nil
        tearDownWebViewOnly()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private static var foregroundWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

private final class TurnstileOverlayViewController: UIViewController {
    private let challengeWebView: WKWebView
    private let onCancel: () -> Void
    private let card = UIView()
    private let dim = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    init(webView: WKWebView, onCancel: @escaping () -> Void) {
        self.challengeWebView = webView
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dim.translatesAutoresizingMaskIntoConstraints = false
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        view.addSubview(dim)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor.secondarySystemBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Cloudflare verification"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Amazon Music playback needs a quick browser check."
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center

        challengeWebView.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(challengeWebView)
        card.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            card.widthAnchor.constraint(equalToConstant: 320),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            challengeWebView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            challengeWebView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            challengeWebView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            challengeWebView.heightAnchor.constraint(equalToConstant: 80),

            cancelButton.topAnchor.constraint(equalTo: challengeWebView.bottomAnchor, constant: 10),
            cancelButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        setChromeVisible(false)
    }

    func setChromeVisible(_ visible: Bool) {
        dim.alpha = visible ? 1 : 0
        titleLabel.isHidden = !visible
        subtitleLabel.isHidden = !visible
        cancelButton.isHidden = !visible
        card.backgroundColor = visible ? UIColor.secondarySystemBackground : .clear
        // WebView stays laid out so CF can still run; host window alpha gates user flash.
    }

    @objc private func cancelTapped() { onCancel() }
}
