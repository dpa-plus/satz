import Foundation
import Security

/// API keys, one per provider.
///
/// On the Mac: a file per provider in satz's own folder, readable only by the
/// user (0600 in a 0700 folder), the same way Handy keeps its key. Not the
/// Keychain, because the login keychain identifies an ad-hoc signed app by
/// its exact build: every rebuild made macOS ask for the user's password
/// before satz could read its own key, and froze the app while it asked.
/// With a real signing certificate the Keychain is the better home again.
///
/// On iOS: the Keychain, which has no such problem.
///
/// Never a file in the bundle, never a preference, never this repository.
public enum Secrets {

    public enum Failure: Error, LocalizedError, Equatable {
        case keychain(OSStatus)
        case file(String)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "Schlüsselbund: \(detail)"
            case .file(let detail):
                return "Schlüssel nicht gespeichert: \(detail)"
            }
        }
    }

    #if os(macOS)
    /// Where the key files live. Replaced by tests.
    nonisolated(unsafe) public static var directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("satz/keys", isDirectory: true)

    private static func file(for provider: Provider) -> URL {
        directory.appendingPathComponent(provider.keychainAccount)
    }

    public static func store(_ secret: String, for provider: Provider) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let target = file(for: provider)
            // Created empty with 0600 first, so the key is never on disk with
            // looser permissions, not even for a moment.
            if !manager.fileExists(atPath: target.path) {
                manager.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(secret.utf8))
        } catch {
            throw Failure.file(error.localizedDescription)
        }
    }

    public static func read(for provider: Provider) -> String? {
        guard let data = try? Data(contentsOf: file(for: provider)) else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public static func exists(for provider: Provider) -> Bool {
        read(for: provider) != nil
    }

    public static func remove(for provider: Provider) {
        try? FileManager.default.removeItem(at: file(for: provider))
    }
    #else

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
    #endif
}
