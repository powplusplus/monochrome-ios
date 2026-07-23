import Foundation
import UIKit
import WebKit

/// Mirrors web Monochrome `getTurnstileJwt`: solve Cloudflare Turnstile on
/// `monochrome.tf` origin, exchange token at Amazon `/api/auth/turnstile`.
@MainActor
final class AmazonTurnstileAuth: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AmazonTurnstileAuth()

    private let jwtKey = "native.amazonTurnstileJwt"
    private let expiryKey = "native.amazonTurnstileExpiry"
    private var webView: WKWebView?
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

            let controller = WKUserContentController()
            controller.add(self, name: "monochromeTurnstile")
            let config = WKWebViewConfiguration()
            config.userContentController = controller

            let webView = WKWebView(frame: CGRect(x: -1200, y: -1200, width: 320, height: 90), configuration: config)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.navigationDelegate = self
            self.webView = webView

            if let window = Self.keyWindow {
                window.addSubview(webView)
            }

            let escapedKey = siteKey
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let html = """
            <!DOCTYPE html><html><head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer></script>
            </head><body>
            <div id="cf"></div>
            <script>
            function boot() {
              if (!window.turnstile) { setTimeout(boot, 40); return; }
              try {
                const id = turnstile.render('#cf', {
                  sitekey: '\(escapedKey)',
                  size: 'invisible',
                  execution: 'execute',
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
                turnstile.execute(id);
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
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
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }
}
