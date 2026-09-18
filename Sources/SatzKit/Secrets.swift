import Foundation
import Security

/// API keys, in the Keychain, one per provider.
///
/// Never a file in the bundle, never a preference, never this repository. The
/// Keychain also means a key survives reinstalling the app and is readable only
/// by the user who put it there.
public enum Secrets {

    public enum Failure: Error, LocalizedError, Equatable {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "Schlüsselbund: \(detail)"
            }
        }
    }

    private static let service = "plus.dpa.satz"

    /// Replaces the stored key in place, or adds one if there is none.
    ///
    /// Update rather than delete-then-add: if the add failed after the delete,
    /// the old key would be gone and the new one not stored.
    public static func store(_ secret: String, for provider: Provider) throws {
        let data = Data(secret.utf8)
        let item = query(for: provider)

        let updated = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.keychain(updated) }

        var insert = item
        insert[kSecValueData as String] = data
        // Honoured by the data-protection keychain (iOS). The file-based macOS
        // login keychain accepts the attribute and silently ignores it, so on
        // the Mac this is not what protects the key: the login keychain being
        // locked with the user's password is.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
    }

    public static func read(for provider: Provider) -> String? {
        var search = query(for: provider)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether a key is stored, without reading it.
    ///
    /// Asks for the item's attributes only. Reading the secret itself can make
    /// macOS show an access prompt, and a settings window that checks status
    /// repeatedly must never cause one.
    public static func exists(for provider: Provider) -> Bool {
        var search = query(for: provider)
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(search as CFDictionary, nil) == errSecSuccess
    }

    public static func remove(for provider: Provider) {
        SecItemDelete(query(for: provider) as CFDictionary)
    }

    private static func query(for provider: Provider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount,
        ]
    }
}
