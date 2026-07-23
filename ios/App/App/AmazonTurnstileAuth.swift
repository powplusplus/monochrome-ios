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
    /// Whether the solve currently in flight is allowed to put a challenge card
    /// on screen. A silent prewarm must never be reused to satisfy a caller that
    /// the user is actively waiting on — see `accessToken`.
    private var inFlightAllowsInteractive = true
    private var inFlightGeneration = 0
    private var mode: ChallengeMode = .interactionOnly
    private var siteKeyForRetry: String = ""
    private var allowInteractive = true

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

    /// Solve the challenge ahead of time so the first play does not pay for it.
    ///
    /// Amazon is gated: every `/api/track/` call 428s until a JWT exists, so the
    /// very first track of a session waited on a WKWebView boot plus a full
    /// Cloudflare round trip before the lookup even started. That work does not
    /// depend on which track is chosen, so do it while the user is still
    /// browsing. Silent by construction — if Cloudflare wants a tap, this gives
    /// up rather than throwing a verification card at someone who has not asked
    /// for anything yet, and the interactive path runs as before on first play.
    func prewarm() {
        guard PlaybackSourceSettings.amazonEnabled,
              PlaybackSourceSettings.amazonBypassToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cachedJWT() == nil,
              inFlight == nil else { return }
        let base = PlaybackSourceSettings.amazonApiBaseURL
        Task { [weak self] in
            // The solve puts an alert-level window on screen (transparent, and
            // non-interactive, but still key). Let the app finish presenting its
            // own UI before doing that at launch.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.cachedJWT() == nil, self.inFlight == nil else { return }
            _ = try? await self.accessToken(apiBaseURL: base, allowInteractive: false, timeout: 15)
        }
    }

    func accessToken(
        apiBaseURL: String,
        siteKey: String = PlaybackSourceSettings.amazonTurnstileSiteKey,
        forceRefresh: Bool = false,
        allowInteractive: Bool = true,
        timeout: TimeInterval = 60
    ) async throws -> String {
        if !forceRefresh, let cached = cachedJWT() { return cached }
        // Only ride along on a solve that is at least as capable as this one
        // needs. Without this check a play tapped during a silent prewarm would
        // inherit the prewarm's failure and never get its own visible attempt.
        if let inFlight, !forceRefresh, inFlightAllowsInteractive || !allowInteractive {
            return try await inFlight.value
        }

        let task = Task<String, Error> {
            if forceRefresh { clearCache() }
            let turnstileToken = try await solveTurnstile(
                siteKey: siteKey,
                allowInteractive: allowInteractive,
                timeout: timeout
            )
            let base = apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/api/auth/turnstile") else {
                throw ServiceError.invalidResponse
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // The exchange endpoint sits behind the same origin check as the
            // media routes.
            request.setValue("https://monochrome.tf", forHTTPHeaderField: "Origin")
            request.setValue("https://monochrome.tf/", forHTTPHeaderField: "Referer")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "cf_turnstile_response": turnstileToken
            ])
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                // Naming the leg matters: a bare "The request timed out." was
                // indistinguishable from the track lookup timing out.
                throw ServiceError.unavailable("Amazon Turnstile exchange timed out")
            }
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let detail = (body?["detail"] as? String) ?? (body?["error"] as? String)
                throw detail.map { ServiceError.unavailable("Amazon Turnstile: \($0)") } ?? ServiceError.http(http.statusCode)
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let jwt = object?["access_token"] as? String, !jwt.isEmpty else {
                throw ServiceError.malformed("Amazon Turnstile JWT")
            }
            let expiry = Self.expiryMilliseconds(forJWT: jwt)
            UserDefaults.standard.set(jwt, forKey: jwtKey)
            UserDefaults.standard.set(expiry, forKey: expiryKey)
            return jwt
        }
        // An interactive caller that refuses to ride along on a silent prewarm
        // replaces `inFlight`. The prewarm's own `defer` then runs *after* that
        // swap, so clearing unconditionally would drop the live solve on the
        // floor and let a third caller start a second WKWebView. Only the task
        // that still owns the slot may clear it.
        inFlightGeneration &+= 1
        let generation = inFlightGeneration
        inFlight = task
        inFlightAllowsInteractive = allowInteractive
        defer { if inFlightGeneration == generation { inFlight = nil } }
        return try await task.value
    }

    /// The provider signs the JWT with its own `exp`. Assuming a flat hour past
    /// the moment the response lands overshoots that by the request latency and
    /// by any device clock skew, so the tail of every cached hour is served with
    /// a token the server already considers dead — it answers 401 "Invalid
    /// Turnstile JWT", which surfaces as an unplayable track. Read the real
    /// expiry off the token and retire it a minute early.
    nonisolated static func expiryMilliseconds(forJWT jwt: String) -> Double {
        let fallback = Date().timeIntervalSince1970 * 1000 + 55 * 60 * 1000
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2,
              let payload = base64URLDecoded(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue, exp > 0 else {
            return fallback
        }
        return (exp - 60) * 1000
    }

    nonisolated private static func base64URLDecoded(_ value: String) -> Data? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text)
    }

    /// HTML loaded into WKWebView. Exposed for unit tests.
    nonisolated static func challengeHTML(siteKey: String, mode: ChallengeMode) -> String {
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

    private func solveTurnstile(
        siteKey: String,
        allowInteractive: Bool,
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.finishPending(with: .failure(CancellationError()))
            self.continuation = continuation
            self.siteKeyForRetry = siteKey
            self.mode = .interactionOnly
            self.allowInteractive = allowInteractive

            guard Self.foregroundWindowScene != nil else {
                self.continuation = nil
                continuation.resume(throwing: ServiceError.unavailable("Amazon Turnstile needs an active window"))
                return
            }

            presentChallenge(siteKey: siteKey, mode: .interactionOnly, showOverlay: false)

            let deadline = DispatchWorkItem { [weak self] in
                self?.finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile timed out")))
            }
            timeoutItem = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
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
        guard allowInteractive else {
            finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile needs interaction")))
            return
        }
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
                // A silent prewarm bows out here rather than surfacing a card the
                // user never asked for; first play then solves it interactively.
                guard allowInteractive else {
                    finishPending(with: .failure(ServiceError.unavailable("Amazon Turnstile needs interaction")))
                    return
                }
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
