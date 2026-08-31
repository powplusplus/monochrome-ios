import Foundation
import UIKit
import WebKit

/// A Turnstile-gated provider. The solved Cloudflare token is single-use, so
/// each exchange keeps its own session token and its own in-flight slot.
///
/// Declared outside `AmazonTurnstileAuth` so the descriptors stay reachable from
/// the non-isolated resolvers that need them.
struct TurnstileExchange: Sendable {
    let id: String
    /// Path appended to the provider base URL.
    let path: String
    /// Name of the JSON field the exchange expects the Turnstile token in.
    let tokenField: String
    /// Prefix for surfaced errors, so a failure names the leg that produced it.
    let label: String
    let tokenKey: String
    let expiryKey: String

    static let amazon = TurnstileExchange(
        id: "amazon",
        path: "/api/auth/turnstile",
        tokenField: "cf_turnstile_response",
        label: "Amazon Turnstile",
        tokenKey: "native.amazonTurnstileJwt",
        expiryKey: "native.amazonTurnstileExpiry"
    )

    /// Unified Playback exchanges the solve for a short-lived JWT it wants back
    /// in `X-Turnstile-JWT`. Same path as Amazon's old exchange, different
    /// request field and its own token cache.
    static let unified = TurnstileExchange(
        id: "unified",
        path: "/api/auth/turnstile",
        tokenField: "turnstile_token",
        label: "Unified Playback Turnstile",
        tokenKey: "native.unifiedTurnstileJwt",
        expiryKey: "native.unifiedTurnstileExpiry"
    )
}

/// Mirrors web Monochrome `getTurnstileJwt`: solve Cloudflare Turnstile on
/// `monochrome.tf` origin, exchange the token for a provider session.
///
/// Unified Playback and the legacy Amazon exchange sit behind the same
/// Cloudflare site key and the same origin check, so the solve itself is
/// shared; only the exchange endpoint, its request field and the token cache
/// differ (see `Exchange`).
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

    typealias Exchange = TurnstileExchange

    private var webView: WKWebView?
    private var hostWindow: UIWindow?
    private var overlay: TurnstileOverlayViewController?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutItem: DispatchWorkItem?
    private var inFlight: [String: Task<String, Error>] = [:]
    /// Whether the solve currently in flight is allowed to put a challenge card
    /// on screen. A silent prewarm must never be reused to satisfy a caller that
    /// the user is actively waiting on — see `accessToken`.
    private var inFlightAllowsInteractive: [String: Bool] = [:]
    private var inFlightGeneration: [String: Int] = [:]
    /// Only one WKWebView challenge can be on screen at a time. Two exchanges
    /// asking at once (a launch prewarm + a tapped play re-solving after a 401)
    /// used to have the second solve cancel the first out from under it.
    private var solveQueue: Task<Void, Never>?
    private var mode: ChallengeMode = .interactionOnly
    private var siteKeyForRetry: String = ""
    private var actionForRetry: String = ""
    private var allowInteractive = true
    /// Last code Cloudflare handed the widget's `error-callback`, kept across the
    /// invisible → visible retry so the surfaced failure still names the cause.
    private var lastChallengeErrorCode: String?

    func cachedJWT(for exchange: Exchange = .amazon) -> String? {
        let jwt = UserDefaults.standard.string(forKey: exchange.tokenKey) ?? ""
        let expiry = UserDefaults.standard.double(forKey: exchange.expiryKey)
        guard !jwt.isEmpty, Date().timeIntervalSince1970 * 1000 < expiry else { return nil }
        return jwt
    }

    func clearCache(for exchange: Exchange = .amazon) {
        UserDefaults.standard.removeObject(forKey: exchange.tokenKey)
        UserDefaults.standard.removeObject(forKey: exchange.expiryKey)
    }

    /// Solve the challenge ahead of time so the first play does not pay for it.
    ///
    /// Both resolvers are gated: every lookup is rejected until a session token
    /// exists, so the very first track of a session waited on a WKWebView boot
    /// plus a full Cloudflare round trip before the lookup even started. That
    /// work does not depend on which track is chosen, so do it while the user is
    /// still browsing. Silent by construction — if Cloudflare wants a tap, this
    /// gives up rather than throwing a verification card at someone who has not
    /// asked for anything yet, and the interactive path runs as before on first
    /// play.
    ///
    /// Only the leg that actually runs first is prewarmed; solving both would put
    /// two challenges on screen at launch to save a round trip the second leg
    /// usually never makes.
    func prewarm() {
        guard let (exchange, base, bypass, siteKey, action) = Self.prewarmTarget() else { return }
        guard bypass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cachedJWT(for: exchange) == nil,
              inFlight[exchange.id] == nil else { return }
        Task { [weak self] in
            // The solve puts an alert-level window on screen (transparent, and
            // non-interactive, but still key). Let the app finish presenting its
            // own UI before doing that at launch.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.cachedJWT(for: exchange) == nil, self.inFlight[exchange.id] == nil else { return }
            _ = try? await self.accessToken(
                apiBaseURL: base,
                exchange: exchange,
                siteKey: siteKey,
                action: action,
                allowInteractive: false,
                timeout: 15
            )
        }
    }

    /// Which leg the launch prewarm solves for, and the settings it must use.
    /// The exchange publishes its own Cloudflare site key and action, and
    /// `accessToken` defaults to the legacy Amazon pair, so naming them here
    /// keeps the prewarm solving the right widget if either side rotates or a
    /// user overrides one in Settings.
    ///
    /// Only a client on the shared default API token has to solve at all — one
    /// with its own token is admitted without a JWT, so a prewarm would put a
    /// Cloudflare challenge on screen for nothing.
    nonisolated static func prewarmTarget()
        -> (exchange: Exchange, base: String, bypass: String, siteKey: String, action: String)? {
        guard PlaybackSourceSettings.unifiedEnabled,
              PlaybackSourceSettings.unifiedApiToken == PlaybackSourceSettings.defaultUnifiedApiToken
        else { return nil }
        return (.unified,
                PlaybackSourceSettings.unifiedApiBaseURL,
                "",
                PlaybackSourceSettings.unifiedTurnstileSiteKey,
                PlaybackSourceSettings.unifiedTurnstileAction)
    }

    func accessToken(
        apiBaseURL: String,
        exchange: Exchange = .amazon,
        siteKey: String = PlaybackSourceSettings.unifiedTurnstileSiteKey,
        action: String = PlaybackSourceSettings.unifiedTurnstileAction,
        forceRefresh: Bool = false,
        allowInteractive: Bool = true,
        timeout: TimeInterval = 60
    ) async throws -> String {
        if !forceRefresh, let cached = cachedJWT(for: exchange) { return cached }
        // Only ride along on a solve that is at least as capable as this one
        // needs. Without this check a play tapped during a silent prewarm would
        // inherit the prewarm's failure and never get its own visible attempt.
        if let pending = inFlight[exchange.id], !forceRefresh,
           inFlightAllowsInteractive[exchange.id] == true || !allowInteractive {
            return try await pending.value
        }

        let task = Task<String, Error> {
            if forceRefresh { clearCache(for: exchange) }
            let turnstileToken = try await serializedSolve(
                siteKey: siteKey,
                action: action,
                allowInteractive: allowInteractive,
                timeout: timeout
            )
            let base = apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + exchange.path) else {
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
                exchange.tokenField: turnstileToken
            ])
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                // Naming the leg matters: a bare "The request timed out." was
                // indistinguishable from the track lookup timing out.
                throw ServiceError.unavailable("\(exchange.label) exchange timed out")
            }
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let detail = Self.exchangeErrorDetail(in: data)
                throw detail.map { ServiceError.unavailable("\(exchange.label): \($0)") } ?? ServiceError.http(http.statusCode)
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let jwt = object?["access_token"] as? String, !jwt.isEmpty else {
                throw ServiceError.malformed("\(exchange.label) token")
            }
            // An exchange that hands back an opaque token has no `exp` to
            // read and states the lifetime separately. Prefer that when present
            // and fall back to the JWT claim.
            let expiry: Double
            if let expiresIn = (object?["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 {
                expiry = (Date().timeIntervalSince1970 + max(expiresIn - 60, 30)) * 1000
            } else {
                expiry = Self.expiryMilliseconds(forJWT: jwt)
            }
            UserDefaults.standard.set(jwt, forKey: exchange.tokenKey)
            UserDefaults.standard.set(expiry, forKey: exchange.expiryKey)
            return jwt
        }
        // An interactive caller that refuses to ride along on a silent prewarm
        // replaces `inFlight`. The prewarm's own `defer` then runs *after* that
        // swap, so clearing unconditionally would drop the live solve on the
        // floor and let a third caller start a second WKWebView. Only the task
        // that still owns the slot may clear it.
        let generation = (inFlightGeneration[exchange.id] ?? 0) &+ 1
        inFlightGeneration[exchange.id] = generation
        inFlight[exchange.id] = task
        inFlightAllowsInteractive[exchange.id] = allowInteractive
        defer { if inFlightGeneration[exchange.id] == generation { inFlight[exchange.id] = nil } }
        return try await task.value
    }

    /// These services state failures in their body — some as `{"error": …}`,
    /// FastAPI ones as `{"detail": {"code": "turnstile_failed", "errors": […]}}`.
    /// A bare status code hid which one it was.
    nonisolated static func exchangeErrorDetail(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        for key in ["detail", "error", "message"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
            // FastAPI states a schema rejection as `detail: [{loc, msg, …}]` —
            // an array, unlike every other error these services return. Without
            // this the caller only ever saw a bare "HTTP 422".
            if let issues = object[key] as? [[String: Any]] {
                let messages = issues.compactMap { $0["msg"] as? String }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
            guard let nested = object[key] as? [String: Any] else { continue }
            let code = (nested["code"] as? String) ?? (nested["message"] as? String)
            let errors = (nested["errors"] as? [String])?.joined(separator: ", ")
            switch (code, errors) {
            case let (code?, errors?) where !errors.isEmpty: return "\(code) (\(errors))"
            case let (code?, _): return code
            case let (_, errors?) where !errors.isEmpty: return errors
            default: continue
            }
        }
        return nil
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

    /// The origin the challenge document is served as. Cloudflare matches this
    /// hostname against the site key's allowed domains, so it has to be the
    /// Monochrome web origin the keys were issued for.
    nonisolated static let challengeOrigin = URL(string: "https://monochrome.tf/")!

    /// HTML loaded into WKWebView. Exposed for unit tests.
    nonisolated static func challengeHTML(
        siteKey: String,
        mode: ChallengeMode,
        action: String = ""
    ) -> String {
        let escapedKey = escapeForJS(siteKey)
        // Rendering `action: ''` is not the same as omitting it — an exchange
        // that expects no action rejects an empty one just as loudly as a wrong
        // one, so the line exists only when there is an action to send.
        let actionLine = action.isEmpty ? "" : "\n      action: '\(escapeForJS(action))',"
        let renderOptions: String
        switch mode {
        case .interactionOnly:
            renderOptions = """
                  sitekey: '\(escapedKey)',\(actionLine)
                  execution: 'execute',
                  appearance: 'interaction-only',
                  theme: 'dark',
                  'before-interactive-callback': function() {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ interactive: true });
                  },
                  callback: function(token) {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: true, token: token });
                  },
                  'error-callback': function(code) {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({
                      ok: false, error: 'turnstile_failed', code: code ? String(code) : ''
                    });
                  },
                  'expired-callback': function() {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: false, error: 'turnstile_expired' });
                  }
            """
        case .alwaysVisible:
            renderOptions = """
                  sitekey: '\(escapedKey)',\(actionLine)
                  size: 'compact',
                  execution: 'render',
                  appearance: 'always',
                  theme: 'dark',
                  callback: function(token) {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({ ok: true, token: token });
                  },
                  'error-callback': function(code) {
                    window.webkit.messageHandlers.monochromeTurnstile.postMessage({
                      ok: false, error: 'turnstile_failed', code: code ? String(code) : ''
                    });
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

    nonisolated private static func escapeForJS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// `solveTurnstile` owns a single WKWebView and cancels whatever solve was
    /// already pending, which is correct for a retry but destructive when two
    /// exchanges ask independently. Queue them so the second waits for the first
    /// to finish (or fail) instead of tearing its challenge down mid-flight.
    private func serializedSolve(
        siteKey: String,
        action: String,
        allowInteractive: Bool,
        timeout: TimeInterval
    ) async throws -> String {
        let previous = solveQueue
        let solve = Task<String, Error> { [weak self] in
            if let previous { await previous.value }
            guard let self else { throw CancellationError() }
            return try await self.solveTurnstile(
                siteKey: siteKey,
                action: action,
                allowInteractive: allowInteractive,
                timeout: timeout
            )
        }
        solveQueue = Task { _ = try? await solve.value }
        return try await solve.value
    }

    private func solveTurnstile(
        siteKey: String,
        action: String,
        allowInteractive: Bool,
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.finishPending(with: .failure(CancellationError()))
            self.continuation = continuation
            self.siteKeyForRetry = siteKey
            self.actionForRetry = action
            self.mode = .interactionOnly
            self.lastChallengeErrorCode = nil
            self.allowInteractive = allowInteractive

            guard Self.foregroundWindowScene != nil else {
                self.continuation = nil
                continuation.resume(throwing: ServiceError.unavailable("Turnstile needs an active window"))
                return
            }

            presentChallenge(siteKey: siteKey, action: action, mode: .interactionOnly, showOverlay: false)

            let deadline = DispatchWorkItem { [weak self] in
                self?.finishPending(with: .failure(ServiceError.unavailable("Turnstile timed out")))
            }
            timeoutItem = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
    }

    private func presentChallenge(siteKey: String, action: String, mode: ChallengeMode, showOverlay: Bool) {
        tearDownWebViewOnly()

        guard let scene = Self.foregroundWindowScene else {
            finishPending(with: .failure(ServiceError.unavailable("Turnstile needs an active window")))
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
            self?.finishPending(with: .failure(ServiceError.unavailable("Turnstile cancelled")))
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

        // The document must *be* an allowlisted Monochrome page, not merely claim
        // one as its base URL: `loadHTMLString(_:baseURL:)` leaves the content in
        // an opaque origin, so `window.origin` is null and storage access throws
        // — which Turnstile reports as a plain widget error. `loadSimulatedRequest`
        // gives the same HTML a real `https://monochrome.tf/` origin.
        let request = URLRequest(url: Self.challengeOrigin)
        let response = HTTPURLResponse(
            url: Self.challengeOrigin,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        webView.loadSimulatedRequest(
            request,
            response: response,
            responseData: Data(Self.challengeHTML(siteKey: siteKey, mode: mode, action: action).utf8)
        )
    }

    private func revealOverlay() {
        guard let window = hostWindow, let overlay else { return }
        window.alpha = 1
        window.isUserInteractionEnabled = true
        window.isHidden = false
        window.makeKeyAndVisible()
        overlay.setChromeVisible(true)
    }

    /// Cloudflare's numeric codes are the difference between a configuration
    /// problem and a transient one, so keep them in the surfaced text.
    nonisolated static func describe(_ detail: String, code: String?) -> String {
        guard let code, !code.isEmpty else { return detail }
        return "\(detail) [\(code)]"
    }

    private func retryVisibleFallback() {
        guard allowInteractive else {
            finishPending(with: .failure(ServiceError.unavailable("Turnstile needs interaction")))
            return
        }
        guard mode == .interactionOnly else {
            finishPending(with: .failure(ServiceError.unavailable(
                "Turnstile: \(Self.describe("turnstile_failed", code: lastChallengeErrorCode))")))
            return
        }
        presentChallenge(siteKey: siteKeyForRetry, action: actionForRetry, mode: .alwaysVisible, showOverlay: true)
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
                    finishPending(with: .failure(ServiceError.unavailable("Turnstile needs interaction")))
                    return
                }
                revealOverlay()
                return
            }
            if body["ok"] as? Bool == true, let token = body["token"] as? String, !token.isEmpty {
                finishPending(with: .success(token))
            } else {
                let detail = body["error"] as? String ?? "turnstile_failed"
                // Cloudflare's error code is the only thing that distinguishes
                // "this domain is not on the site key" (110200) from "this
                // browser/embedding is refused" (600010) from a plain network
                // failure. Without it every cause read as `turnstile_failed`.
                if let code = body["code"] as? String, !code.isEmpty { lastChallengeErrorCode = code }
                if detail == "turnstile_failed", mode == .interactionOnly {
                    retryVisibleFallback()
                    return
                }
                finishPending(with: .failure(ServiceError.unavailable("Turnstile: \(Self.describe(detail, code: lastChallengeErrorCode))")))
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
        subtitleLabel.text = "Playback needs a quick browser check."
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
