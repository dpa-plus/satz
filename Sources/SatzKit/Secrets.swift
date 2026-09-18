import Foundation
import Security

/// The OpenAI key, in the Keychain.
///
/// Never a file in the bundle, never a preference, never this repository. The
/// Keychain also means the key survives reinstalling the app and is readable
/// only by the user who put it there.
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

    public static let openAIAccount = "openai"

    private static let service = "plus.dpa.satz"

    public static func store(_ secret: String, account: String = openAIAccount) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = Data(secret.utf8)
        // Honoured by the data-protection keychain (iOS). The file-based macOS
        // login keychain accepts the attribute and silently ignores it, so on
        // the Mac this is not what protects the key: the login keychain being
        // locked with the user's password is.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public static func read(account: String = openAIAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether a key is stored, without reading it.
    ///
    /// Asks for the item's attributes only. Reading the secret itself can make
    /// macOS show an access prompt, and a settings window that checks status
    /// repeatedly must never cause one.
    public static func exists(account: String = openAIAccount) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func remove(account: String = openAIAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
