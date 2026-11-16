import Foundation
import Security

/// Where the identity token is kept between launches.
protocol TokenStore: Sendable {
    func read() -> String?
    func write(_ token: String?)
}

/// The Keychain, one entry per agent.
struct KeychainTokenStore: TokenStore {
    let agentId: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.qwryai.sdk.identity", kSecAttrAccount as String: agentId]
    }

    func read() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String?) {
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        SecItemAdd(query.merging([kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 } as CFDictionary, nil)
    }
}

/// A random ID made once per install. Anonymous conversations belong to it.
func storedDeviceId(in defaults: UserDefaults) -> String {
    let key = "com.qwryai.sdk.deviceId"
    if let existing = defaults.string(forKey: key) { return existing }
    let created = UUID().uuidString.lowercased()
    defaults.set(created, forKey: key)
    return created
}

/// The user a token names. The server verifies the token; this only reads it, to restore the signed-in state on launch.
func userId(inToken token: String) -> String? {
    let segments = token.split(separator: ".")
    guard segments.count == 3 else { return nil }
    var payload = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
    switch claims["user_id"] ?? claims["sub"] {
    case .string(let id): return id
    case .number(let id): return String(Int(id))
    default: return nil
    }
}
