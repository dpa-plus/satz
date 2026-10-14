import Foundation

// Rules that Settings, Setup and the app share. They sit here, away from the
// views, so one definition serves every caller and the tests can reach it:
// the Mac app's own target has no tests.

// MARK: - Where a key may be sent

/// Where a request that carries a key may go.
///
/// https goes anywhere. Plain http only to an address on one's own network,
/// where nobody on the way can read it: this computer, a private or
/// link-local address, a name that only exists inside a network. Windows and
/// Linux apply the same rule (`desktop/src/core/browse.ts`); the two lists
/// are meant to say the same.
public enum ProviderAddress {

    /// Names that only mean something inside a network. A name that merely
    /// contains one ("nas.local.example.com") ends differently and is not one.
    static let privateSuffixes = [".local", ".lan", ".home.arpa", ".internal"]

    /// The names that mean this computer: a model server of one's own, or a
    /// stand-in server in a test. `127.0.0.0/8` is all of it, not only
    /// 127.0.0.1, and `[::1]` is its IPv6 twin.
    public static func isThisComputer(_ host: String) -> Bool {
        place(of: host) == .thisComputer
    }

    /// Whether plain http may go to `host`: this computer, a private or
    /// link-local address, a host name without a dot ("nas"), or a name under
    /// `.local`, `.lan`, `.home.arpa` or `.internal`.
    public static func isOnOwnNetwork(_ host: String) -> Bool {
        place(of: host) != .elsewhere
    }

    /// https to any host, http only on one's own network. `scheme` is
    /// lowercase. An empty host is never a place.
    public static func allows(scheme: String, host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return scheme == "https" || (scheme == "http" && isOnOwnNetwork(host))
    }

    // MARK: Reading a host

    private enum Place { case thisComputer, ownNetwork, elsewhere }

    /// Where a host is, from its spelling alone: no name is looked up, so
    /// what DNS would answer for a name never decides.
    private static func place(of text: String) -> Place {
        var host = text.lowercased()
        // URL.host hands an IPv6 address over bare; URLComponents brackets it.
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return .elsewhere }

        if host.contains(":") { return placeOfIPv6(host) }
        if host == "localhost" { return .thisComputer }
        if let octets = ipv4(host) { return placeOfIPv4(octets) }

        // No dot: a name of the network the computer is on ("nas", resolved
        // by its own search domain or by mDNS), as long as it is a name. All
        // digits or "0x…" is a number that getaddrinfo reads as an IPv4
        // address ("134744072" is 8.8.8.8), so it would let http reach a
        // public host dressed as a name.
        if !host.contains(".") { return isName(host) && !isNumber(host) ? .ownNetwork : .elsewhere }

        for suffix in privateSuffixes where host.hasSuffix(suffix) {
            let name = host.dropLast(suffix.count)
            if name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ isName(String($0)) }) { return .ownNetwork }
        }
        return .elsewhere
    }

    private static func placeOfIPv4(_ octets: [UInt8]) -> Place {
        switch (octets[0], octets[1]) {
        case (127, _): .thisComputer
        case (10, _), (172, 16 ... 31), (192, 168), (169, 254): .ownNetwork
        default: .elsewhere
        }
    }

    private static func placeOfIPv6(_ text: String) -> Place {
        // A link-local address names its network interface after a %
        // ("fe80::1%en0"); the address is what counts.
        let bare = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        guard let bytes = ipv6(bare) else { return .elsewhere }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .thisComputer }
        // fc00::/7 (unique local) and fe80::/10 (link-local).
        if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return .ownNetwork }
        return .elsewhere
    }

    /// Four decimal numbers up to 255, written plainly. Nothing else is an
    /// address here: getaddrinfo reads "127.1" as 127.0.0.1, "0x7f.1" the
    /// same and "010.0.0.1" as 8.0.0.1 (a leading 0 is octal), and inet_pton
    /// on this Mac takes "010.0.0.1" for 10.0.0.1, so none of them may pass
    /// as the address they look like. They have dots and no local ending, so
    /// they are names, and need https.
    private static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), part == "0" || !part.hasPrefix("0"),
                  let octet = UInt8(part) else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        return inet_pton(AF_INET6, text, &bytes) == 1 ? bytes : nil
    }

    /// Letters, digits, hyphen and underscore, and something of them.
    private static func isName(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x5f
        }
    }

    private static func isNumber(_ label: String) -> Bool {
        if label.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return true }
        return label.hasPrefix("0x") && label.dropFirst(2).utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }
}

// MARK: - What a provider needs

/// What a provider still lacks before it can take a dictation.
///
/// One rule for three places that once each had their own: the "… benutzen"
/// button in Settings offered an own endpoint with only an address, while
/// Setup's Weiter wanted a key, an address and a model.
public enum ProviderReadiness {

    public enum Need: Equatable, Sendable {
        case key
        /// Nothing typed yet.
        case address
        /// An address is typed and cannot be used (`ProviderAddress`). Told
        /// apart from `address` so the message says why, instead of asking
        /// for what is already there.
        case addressRefused
        case model
        /// Lokal: the model chosen is not on this Mac.
        case localModel

        /// Either way, there is nowhere to send the audio.
        public var concernsAddress: Bool { self == .address || self == .addressRefused }
    }

    /// A custom endpoint needs a host to send the audio to, and the address
    /// has to be one the request can really go to (`sendableAddress`).
    public static func hasUsableAddress(_ text: String) -> Bool {
        sendableAddress(text) != nil
    }

    /// The address a custom endpoint is sent to, or nil when there is none
    /// that is safe to use. The one definition for checking and for sending
    /// (`Transcriber.Settings`): a value that passed here is exactly the one
    /// the request goes to, never a second reading of the same text.
    ///
    /// https, or http on one's own network only (`ProviderAddress.allows`),
    /// with a host: the key travels with the audio, and `ftp://…` or a
    /// scheme-relative `//host/v1` used to pass because only a host was
    /// looked for, then failed on every dictation with "unsupported URL".
    public static func sendableAddress(_ text: String) -> URL? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: typed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              ProviderAddress.allows(scheme: scheme, host: host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              scheme == "https" || isSpelledAsRead(parts, host: host) else { return nil }
        // The scheme as it was checked: "HTTPS://host" goes out as "https://host".
        parts.scheme = scheme
        return parts.url
    }

    /// For http, where the host decides whether the address is allowed at
    /// all: `URL.host` decodes percent-encoding, and the address goes out as
    /// it was typed. "192.168.1.5%2eevil.com" reads as 192.168.1.5.evil.com
    /// here, but the network stack is not bound to read it the same way. A
    /// host that needs decoding is refused; only an IPv6 zone
    /// ("fe80::1%25en0") may carry a percent sign. https takes any host, so
    /// an internationalised name stays what it was.
    private static func isSpelledAsRead(_ parts: URLComponents, host: String) -> Bool {
        host.contains(":") || !(parts.percentEncodedHost ?? "").contains("%")
    }

    /// A custom endpoint has no default model; without one every request fails.
    public static func hasModel(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// In the order they are filled in. `hasKey` is the key being saved, or
    /// for Lokal the chosen model being on this Mac. `microsoftEndpoint` is
    /// Microsoft's optional own address: empty means the region is used, and
    /// one that is typed has to be usable.
    public static func missing(_ provider: Provider, hasKey: Bool, customBaseURL: String, model: String,
                               microsoftEndpoint: String = "") -> [Need] {
        switch provider {
        case .local:
            return hasKey ? [] : [.localModel]
        case .microsoft:
            var needs: [Need] = []
            if !hasKey { needs.append(.key) }
            let typed = microsoftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, MicrosoftSpeech.endpointURL(typed) == nil { needs.append(.addressRefused) }
            return needs
        case .custom:
            var needs: [Need] = []
            if !hasKey { needs.append(.key) }
            if !hasUsableAddress(customBaseURL) {
                let typed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                needs.append(typed.isEmpty ? .address : .addressRefused)
            }
            if !hasModel(model) { needs.append(.model) }
            return needs
        default:
            return hasKey ? [] : [.key]
        }
    }

    /// What to tell the user, naming everything that is missing at once, so
    /// filling in one field is not followed by a second surprise. nil when
    /// nothing is. An address that is typed but refused is not "missing": it
    /// is told why, after what else is still to fill in.
    public static func message(_ needs: [Need], in language: Language = .current) -> String? {
        let english = language == .english
        let ask = asking(for: needs.filter { $0 != .addressRefused }, english: english)
        guard needs.contains(.addressRefused) else { return ask }
        // The rule in one line (`ProviderAddress`), the same on every platform.
        let why = english ? "This address won't work: https, or http only on your own network."
                          : "Diese Adresse geht nicht: https, oder http nur im eigenen Netz."
        return ask.map { $0 + ". " + why } ?? why
    }

    private static func asking(for needs: [Need], english: Bool) -> String? {
        if needs == [.localModel] {
            return english ? "Download a model first" : "Erst ein Modell laden"
        }
        let words = needs.compactMap { need -> (de: String, en: String, deWhole: String, enWhole: String)? in
            switch need {
            case .key: ("Schlüssel", "key", "den Schlüssel", "the key")
            case .address: ("Adresse", "address", "die Adresse", "the address")
            case .model: ("Modell", "model", "das Modell", "the model")
            case .addressRefused, .localModel: nil
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
