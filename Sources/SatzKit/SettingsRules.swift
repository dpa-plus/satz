import Foundation

// Rules that Settings, Setup and the app share. They sit here, away from the
// views, so one definition serves every caller and the tests can reach it:
// the Mac app's own target has no tests.

// MARK: - What a provider needs

/// What a provider still lacks before it can take a dictation.
///
/// One rule for three places that once each had their own: the "… benutzen"
/// button in Settings offered an own endpoint with only an address, while
/// Setup's Weiter wanted a key, an address and a model.
public enum ProviderReadiness {

    public enum Need: Equatable, Sendable {
        case key
        case address
        case model
        /// Lokal: the model chosen is not on this Mac.
        case localModel
    }

    /// A custom endpoint needs a host to send the audio to.
    public static func hasUsableAddress(_ text: String) -> Bool {
        URL(string: text.trimmingCharacters(in: .whitespaces))?.host != nil
    }

    /// A custom endpoint has no default model; without one every request fails.
    public static func hasModel(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// In the order they are filled in. `hasKey` is the key being saved, or
    /// for Lokal the chosen model being on this Mac.
    public static func missing(_ provider: Provider, hasKey: Bool, customBaseURL: String, model: String) -> [Need] {
        switch provider {
        case .local:
            return hasKey ? [] : [.localModel]
        case .custom:
            var needs: [Need] = []
            if !hasKey { needs.append(.key) }
            if !hasUsableAddress(customBaseURL) { needs.append(.address) }
            if !hasModel(model) { needs.append(.model) }
            return needs
        default:
            return hasKey ? [] : [.key]
        }
    }

    /// What to tell the user, naming everything that is missing at once, so
    /// filling in one field is not followed by a second surprise. nil when
    /// nothing is.
    public static func message(_ needs: [Need], in language: Language = .current) -> String? {
        let english = language == .english
        if needs == [.localModel] {
            return english ? "Download a model first" : "Erst ein Modell laden"
        }
        let words = needs.compactMap { need -> (de: String, en: String, deWhole: String, enWhole: String)? in
            switch need {
            case .key: ("Schlüssel", "key", "den Schlüssel", "the key")
            case .address: ("Adresse", "address", "die Adresse", "the address")
            case .model: ("Modell", "model", "das Modell", "the model")
            case .localModel: nil
            }
        }
        guard !words.isEmpty else { return nil }
        // One thing keeps its article ("Erst die Adresse eintragen"); several
        // are listed bare ("Erst Adresse und Modell eintragen").
        if words.count == 1 {
            return english ? "Enter \(words[0].enWhole) first" : "Erst \(words[0].deWhole) eintragen"
        }
        let list = list(words.map { english ? $0.en : $0.de }, and: english ? "and" : "und")
        return english ? "Enter the \(list) first" : "Erst \(list) eintragen"
    }

    private static func list(_ items: [String], and word: String) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(word) " + last
    }
}

// MARK: - The switch under the provider menu

/// The row under the provider menu while it shows a provider that dictation
/// does not go to: where it goes now, and the button that changes it. Worded
/// as on Windows and Linux (`desktop/src/core/browse.ts`): "Eigener" and
/// "Lokal" are the menu's words rather than names, so they are quoted, and
/// the button follows the German case ("Eigenen benutzen").
public enum SwitchWording {

    public static func goesTo(_ inUse: Provider, in language: Language = .current) -> String {
        let name = name(inUse, language)
        let generic = inUse == .custom || inUse == .local
        if language == .english {
            return generic ? "Dictation goes to “\(name)”." : "Dictation goes to \(name)."
        }
        return generic ? "Diktate gehen an „\(name)“." : "Diktate gehen an \(name)."
    }

    public static func button(_ shown: Provider, in language: Language = .current) -> String {
        if language == .english { return "Use \(name(shown, language))" }
        return shown == .custom ? "Eigenen benutzen" : "\(name(shown, language)) benutzen"
    }

    /// `Provider.name` in a language of the caller's choosing rather than the
    /// app's current one.
    private static func name(_ provider: Provider, _ language: Language) -> String {
        switch provider {
        case .custom: language == .english ? "Custom" : "Eigener"
        case .local: language == .english ? "Local" : "Lokal"
        default: provider.name
        }
    }
}

// MARK: - Undo

/// Putting back what a "Rückgängig" took out. Adding refuses a word or a
/// phrase that is already there, so Undo must too: removing a word, adding
/// it again and then pressing Undo left it twice, and a replacement restored
/// ahead of the one just typed for the same phrase won (the first rule that
/// matches wins). What was added since stays; what Undo would have brought
/// back is not needed any more.
public enum Restoring {

    /// The same word in any case counts as there.
    public static func containsWord(_ word: String, in words: [String]) -> Bool {
        words.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    /// Where the rule for this phrase stands, if there is one: the same
    /// phrase in any case is the same rule.
    public static func index(ofPhrase spoken: String, in rules: [Replacement]) -> Int? {
        rules.firstIndex { $0.spoken.caseInsensitiveCompare(spoken) == .orderedSame }
    }

    /// `word` back at its old place, unless it is there again.
    public static func word(_ word: String, at index: Int, in words: [String]) -> [String] {
        guard !containsWord(word, in: words) else { return words }
        var restored = words
        restored.insert(word, at: min(max(index, 0), restored.count))
        return restored
    }

    /// `rule` back at its old place, unless its phrase has a rule again.
    public static func rule(_ rule: Replacement, at index: Int, in rules: [Replacement]) -> [Replacement] {
        guard Restoring.index(ofPhrase: rule.spoken, in: rules) == nil else { return rules }
        var restored = rules
        restored.insert(rule, at: min(max(index, 0), restored.count))
        return restored
    }
}
