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
        // Available once the machine has been unlocked, and never synced to
        // other devices: this key belongs to this Mac.
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

    public static func remove(account: String = openAIAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
