import AuthenticationServices
import Foundation
import Observation
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum TokenVault {
    private static let service = "app.anishelf.oauth"
    static func read() -> String? { try? readChecked() }
    static func readChecked() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "anilist",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data:data,encoding:.utf8) else { throw APIError.message("无法读取登录信息：\(status)") }
        return value
    }
    static func write(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "anilist"]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let inserted = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw APIError.message("无法将登录信息存入钥匙串：\(inserted)") }
        } else if status != errSecSuccess { throw APIError.message("钥匙串更新失败：\(status)") }
    }
    static func delete() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                      kSecAttrService as String: service, kSecAttrAccount as String: "anilist"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.message("无法删除登录信息：\(status)") }
    }
}

@MainActor @Observable
final class Authentication: NSObject {
    private(set) var token = TokenVault.read()
    private(set) var isAuthenticating = false
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var presentationContext: AuthenticationPresentationContext?

    func reloadToken(_ value:String?) { token = value }

    func login(clientID: String) async throws {
        guard !isAuthenticating else { return }
        guard !clientID.isEmpty, clientID.allSatisfy(\.isNumber) else { throw APIError.message("请先在设置中填写 AniList Client ID。") }
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else {
            throw APIError.message("请回到 App 窗口后重新登录。")
        }
        let anchor = scene.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor(windowScene: scene)
        #else
        let anchor = NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
        let context = AuthenticationPresentationContext(anchor: anchor)
        presentationContext = context
        isAuthenticating = true
        defer { isAuthenticating = false; session = nil; presentationContext = nil }
        let state = UUID().uuidString + UUID().uuidString
        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "token"), URLQueryItem(name: "state", value: state)]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: OAuthCallback.scheme) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? APIError.message("授权会话没有返回结果。")) }
            }
            self.session = session
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() { continuation.resume(throwing: APIError.message("无法打开系统登录窗口。")) }
        }
        let token = try OAuthCallback.token(from: callback, expectedState: state)
        _ = try await AniListAPI.shared.viewer(token: token)
        let previous = try Credentials.readChecked("anilist.token")
        try Credentials.write("anilist.token",token)
        do { try TokenVault.write(token) }
        catch { try Credentials.write("anilist.token",previous); throw error }
        self.token = token
    }

    func logout() throws {
        try Credentials.write("anilist.token","")
        try TokenVault.delete()
        session?.cancel()
        token = nil
    }
}

@MainActor
private final class AuthenticationPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
