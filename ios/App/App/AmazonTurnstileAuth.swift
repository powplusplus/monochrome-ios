import Foundation
import UIKit
import WebKit

/// Mirrors web Monochrome `getTurnstileJwt`: solve Cloudflare Turnstile on
/// `monochrome.tf` origin, exchange token at Amazon `/api/auth/turnstile`.
///
/// Invisible off-screen WKWebViews fail Cloudflare checks on iOS. Present a
/// compact on-screen challenge (same idea as web's Turnstile panel).
@MainActor
final class AmazonTurnstileAuth: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AmazonTurnstileAuth()

    private let jwtKey = "native.amazonTurnstileJwt"
    private let expiryKey = "native.amazonTurnstileExpiry"
    private var webView: WKWebView?
    private var hostWindow: UIWindow?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutItem: DispatchWorkItem?
    private var inFlight: Task<String, Error>?

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

    private func solveTurnstile(siteKey: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.finishPending(with: .failure(CancellationError()))
            self.continuation = continuation

            guard let scene = Self.foregroundWindowScene else {
                self.continuation = nil
                continuation.resume(throwing: ServiceError.unavailable("Amazon Turnstile needs an active window"))
                return
            }

            let controller = WKUserContentController()
            controller.add(self, name: "monochromeTurnstile")
            let config = WKWebViewConfiguration()
            config.userContentController = controller
            // Cloudflare scripts expect a normal browser-like web view.
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

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = overlay
            window.makeKeyAndVisible()
            self.hostWindow = window

            let escapedKey = siteKey
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            // Compact widget is interactive and reliable in WKWebView; invisible
            // off-screen challenges are routinely rejected on iOS.
            let html = """
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
                turnstile.render('#cf', {
                  sitekey: '\(escapedKey)',
                  size: 'compact',
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
                });
              } catch (e) {
                window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: false, error: String(e) });
              }
            }
            boot();
            </script>
            </body></html>
            """
            // baseURL must be an allowlisted Monochrome host so Turnstile accepts the site key.
            webView.loadHTMLString(html, baseURL: URL(string: "https://monochrome.tf/"))

            let timeout = DispatchWorkItem { [weak self] in
                self?.finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile timed out")))
            }
            timeoutItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        }
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard message.name == "monochromeTurnstile" else { return }
            guard let body = message.body as? [String: Any] else {
                finishPending(with: .failure(ServiceError.malformed("Turnstile message")))
                return
            }
            if body["ok"] as? Bool == true, let token = body["token"] as? String, !token.isEmpty {
                finishPending(with: .success(token))
            } else {
                let detail = body["error"] as? String ?? "turnstile_failed"
                finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile: \(detail)")))
            }
        }
    }

    private func finishPending(with result: Result<String, Error>) {
        timeoutItem?.cancel()
        timeoutItem = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "monochromeTurnstile")
        webView?.removeFromSuperview()
        webView = nil
        hostWindow?.isHidden = true
        hostWindow?.rootViewController = nil
        hostWindow = nil
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
        view.backgroundColor = UIColor.black.withAlphaComponent(0.55)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor.secondarySystemBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Cloudflare verification"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.text = "Amazon Music playback needs a quick browser check."
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        challengeWebView.translatesAutoresizingMaskIntoConstraints = false

        let cancel = UIButton(type: .system)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        card.addSubview(title)
        card.addSubview(subtitle)
        card.addSubview(challengeWebView)
        card.addSubview(cancel)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            card.widthAnchor.constraint(equalToConstant: 320),

            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            subtitle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            challengeWebView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            challengeWebView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            challengeWebView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            challengeWebView.heightAnchor.constraint(equalToConstant: 80),

            cancel.topAnchor.constraint(equalTo: challengeWebView.bottomAnchor, constant: 10),
            cancel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            cancel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
    }

    @objc private func cancelTapped() { onCancel() }
}
