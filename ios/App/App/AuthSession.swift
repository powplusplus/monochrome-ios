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
        } catch { errorMessage = error.localizedDescription }
    }

    func social(provider: String) {
        guard let callback = URL(string: "monochrome://auth-callback"),
              let url = URL(string: "https://auth.monochrome.tf/api/native/oauth/start?provider=\(provider)&callbackURL=\(callback.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "monochrome") { [weak self] callbackURL, error in
            Task { @MainActor in
                if let error { self?.errorMessage = error.localizedDescription; return }
                if let callbackURL { self?.handle(callbackURL) }
            }
        }
        session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = false
        webSession = session; session.start()
    }

    func handle(_ url: URL) {
        guard url.scheme == "monochrome", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let secret = components.queryItems?.first(where: { $0.name == "secret" || $0.name == "token" })?.value else { return }
        do { try Keychain.write(secret, account: "bearer"); isSignedIn = true } catch { errorMessage = error.localizedDescription }
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
