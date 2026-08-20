import Foundation
import Security

/// Deploy credentials, kept in the Keychain.
///
/// The point of this file is what it is *not*: an environment variable. A
/// deploy token in the environment is a deploy token in every child process,
/// every crash log and every `ps` listing. The Keychain scopes it to this app
/// and puts its lifetime under the user's control.
public enum Keychain {

    /// Where bvx's own secrets live.
    private static let service = "com.qjam.bvx"

    public enum Credential: String, Sendable, CaseIterable {
        case githubToken = "github-token"
        case cloudflareToken = "cloudflare-token"

        public var displayName: String {
            switch self {
            case .githubToken: "GitHub token"
            case .cloudflareToken: "Cloudflare token"
            }
        }
    }

    /// Reads a credential, or nil when none is stored.
    public static func read(_ credential: Credential) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// Stores a credential, replacing any previous one.
    ///
    /// An empty value deletes rather than storing an empty secret, so
    /// clearing the field in the UI really does remove the credential.
    @discardableResult
    public static func write(_ credential: Credential, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(credential) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            // Available whenever the device is unlocked, and never synced to
            // another machine: a deploy token is machine-local by nature.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        if updated == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    public static func delete(_ credential: Credential) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static func has(_ credential: Credential) -> Bool {
        read(credential) != nil
    }
}
