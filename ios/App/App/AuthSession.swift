import AuthenticationServices
import Foundation
import Security
import UIKit

@MainActor
final class AuthSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthSession()
    @Published private(set) var isSignedIn = false
    @Published private(set) var profile: Profile?
    @Published var errorMessage: String?
    private var webSession: ASWebAuthenticationSession?
    private let authBase = URL(string: "https://auth.monochrome.tf")!

    override init() {
        super.init(); isSignedIn = Keychain.read("bearer") != nil
    }

    func signIn(email: String, password: String) async {
        do {
            var request = URLRequest(url: authBase.appendingPathComponent("api/auth/sign-in/email"))
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ServiceError.authenticationRequired }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let secret = object?["secret"] as? String ?? object?["token"] as? String else { throw ServiceError.malformed("session token") }
            try Keychain.write(secret, account: "bearer"); isSignedIn = true
            await LibraryRepository.shared.syncWithCloud()
        } catch { errorMessage = error.localizedDescription }
    }

    func social(provider: String) {
        Task { await beginSocial(provider: provider) }
    }

    private func beginSocial(provider: String) async {
        do {
            let callbackURL = authBase.appendingPathComponent("api/native/oauth/callback").absoluteString
            var request = URLRequest(url: authBase.appendingPathComponent("api/auth/sign-in/social"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "provider": provider,
                "callbackURL": callbackURL,
                "errorCallbackURL": callbackURL,
                "disableRedirect": true
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            let object = try? JSONSerialization.jsonObject(with: data)
            guard (200..<300).contains(http.statusCode) else {
                throw ServiceError.unavailable(Self.authError(from: object) ?? "OAuth request failed with HTTP \(http.statusCode).")
            }
            let redirectedURL = http.url.flatMap { $0.scheme == "https" && $0.absoluteString != request.url?.absoluteString ? $0 : nil }
            guard let url = Self.oauthURL(from: object) ?? redirectedURL else {
                throw ServiceError.malformed("OAuth authorization URL")
            }
            openWebAuthentication(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openWebAuthentication(_ url: URL) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "monochrome") { [weak self] callbackURL, error in
            Task { @MainActor in
                if let authenticationError = error as? ASWebAuthenticationSessionError,
                   authenticationError.code == .canceledLogin { return }
                if let error { self?.errorMessage = error.localizedDescription; return }
                if let callbackURL { self?.handle(callbackURL) }
            }
        }
        session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = false
        webSession = session; session.start()
    }

    func handle(_ url: URL) {
        guard url.scheme == "monochrome", url.host == "auth-callback" else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.queryItems?.isEmpty != false, let fragment = components?.fragment {
            components = URLComponents(string: "?\(fragment)")
        }
        let items = components?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error_description" })?.value ?? items.first(where: { $0.name == "error" })?.value {
            errorMessage = error
            return
        }
        guard let secret = items.first(where: { $0.name == "secret" || $0.name == "token" })?.value else {
            errorMessage = "The authentication callback did not contain a session token."
            return
        }
        do {
            try Keychain.write(secret, account: "bearer")
            isSignedIn = true
            errorMessage = nil
            Task { await loadProfile(); await LibraryRepository.shared.syncWithCloud() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadProfile() async {
        guard let token = Keychain.read("bearer") else { return }
        do {
            var request = URLRequest(url: authBase.appendingPathComponent("api/me"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let user = object["user"] as? [String: Any] ?? object
            let id = ModelMapper.string(user, ["id", "userId"]) ?? "me"
            let name = ModelMapper.string(user, ["name", "displayName", "email"]) ?? "Monochrome User"
            profile = Profile(id: id, name: name, username: ModelMapper.string(user, ["username", "email"]), picture: ModelMapper.string(user, ["image", "avatar", "avatarUrl"]))
        } catch { /* A valid bearer remains usable if profile enrichment is unavailable. */ }
    }

    static func oauthURL(from object: Any?) -> URL? {
        guard let object else { return nil }
        if let value = object as? String, let url = URL(string: value), url.scheme == "https" { return url }
        if let dictionary = object as? [String: Any] {
            for key in ["url", "redirectURL", "redirectUrl"] {
                if let value = dictionary[key] as? String, let url = URL(string: value), url.scheme == "https" { return url }
            }
            if let url = oauthURL(from: dictionary["data"]) { return url }
        }
        return nil
    }

    static func authError(from object: Any?) -> String? {
        if let text = object as? String, !text.isEmpty { return text }
        guard let dictionary = object as? [String: Any] else { return nil }
        if let message = dictionary["message"] as? String { return message }
        if let error = dictionary["error"] as? String { return error }
        if let error = dictionary["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return nil
    }

    func signOut() { Keychain.delete("bearer"); isSignedIn = false; profile = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor() }
}

enum Keychain {
    static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        delete(account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tf.monochrome.music", kSecAttrAccount as String: account, kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ServiceError.unavailable("The secret could not be saved securely.") }
    }
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tf.monochrome.music", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tf.monochrome.music", kSecAttrAccount as String: account] as CFDictionary)
    }
}
