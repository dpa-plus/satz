import Foundation

/// One key file in satz's keys folder, and how its field presents it.
///
/// A key belongs to an account, not to a use: the OpenRouter key that
/// transcribes also cleans up, and is the same file. The name is the file's
/// name (`Secrets`), so it never changes once keys are stored under it.
public struct KeyAccount: Hashable, Sendable, Identifiable {
    /// The file name: "openrouter", "anthropic", "azure-openai".
    public let name: String
    /// What a key looks like, as the field's placeholder.
    public let placeholder: String
    /// Where to create one.
    public let page: URL?
    /// One sentence under the key, where getting it has a catch.
    public let note: String?
    /// The custom cleanup endpoint works without one (a server on this computer).
    public let isOptional: Bool

    public var id: String { name }

    public init(_ name: String, placeholder: String, page: URL? = nil, note: String? = nil, isOptional: Bool = false) {
        self.name = name
        self.placeholder = placeholder
        self.page = page
        self.note = note
        self.isOptional = isOptional
    }
}

extension Provider {
    /// The key file transcription with this provider reads.
    public var keyAccount: KeyAccount {
        KeyAccount(keychainAccount, placeholder: keyPlaceholder, page: keyPage, note: keyNote)
    }
}
