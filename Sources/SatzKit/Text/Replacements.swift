import Foundation

/// A word you say that becomes something else on the page: "Klammer auf"
/// becomes "(", "neue Zeile" a line break.
///
/// Transcription models write spoken punctuation out as words (tested with
/// MAI-Transcribe and GPT Transcribe, German and English), so this is plain
/// find and replace on the transcript. No second model, nothing guessed.
public struct Replacement: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    /// What you say, written the way the model spells it.
    public var spoken: String
    /// What lands in the text.
    public var written: String
    public var isOn = true

    public init(spoken: String, written: String, isOn: Bool = true) {
        self.spoken = spoken
        self.written = written
        self.isOn = isOn
    }
}

public enum Replacements {

    /// The predefined rules for the app's language. Mostly two-word phrases,
    /// so normal speech does not trigger them; single words that are also
    /// everyday words ("Punkt", "comma") start switched off.
    public static func standard(for language: Language) -> [Replacement] {
        switch language {
        case .german: [
            Replacement(spoken: "Klammer auf", written: "("),
            Replacement(spoken: "Klammer zu", written: ")"),
            Replacement(spoken: "Zitat Anfang", written: "\""),
            Replacement(spoken: "Zitat Ende", written: "\""),
            Replacement(spoken: "neue Zeile", written: "\n"),
            Replacement(spoken: "neuer Absatz", written: "\n\n"),
            Replacement(spoken: "Doppelpunkt", written: ":"),
            Replacement(spoken: "Fragezeichen", written: "?"),
            Replacement(spoken: "Ausrufezeichen", written: "!"),
            Replacement(spoken: "Punkt", written: ".", isOn: false),
            Replacement(spoken: "Komma", written: ",", isOn: false),
        ]
        case .english: [
            Replacement(spoken: "open bracket", written: "("),
            Replacement(spoken: "close bracket", written: ")"),
            Replacement(spoken: "open quote", written: "\""),
            Replacement(spoken: "close quote", written: "\""),
            Replacement(spoken: "new line", written: "\n"),
            Replacement(spoken: "new paragraph", written: "\n\n"),
            Replacement(spoken: "colon", written: ":"),
            Replacement(spoken: "question mark", written: "?"),
            Replacement(spoken: "exclamation mark", written: "!"),
            Replacement(spoken: "full stop", written: ".", isOn: false),
            Replacement(spoken: "comma", written: ",", isOn: false),
        ]
        }
    }

    /// Whether two lists say the same, ignoring the ids that make every
    /// fresh copy of the predefined rules distinct.
    public static func sameRules(_ a: [Replacement], _ b: [Replacement]) -> Bool {
        a.map { [$0.spoken, $0.written, "\($0.isOn)"] } == b.map { [$0.spoken, $0.written, "\($0.isOn)"] }
    }

    /// The spoken side of every rule that is on, for the model's word list:
    /// a made-up trigger word only survives transcription if the model was
    /// told to expect it.
    public static func phrases(_ rules: [Replacement]) -> [String] {
        rules.filter(\.isOn).map(\.spoken).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `text` with every rule that is on applied, and the commas and spaces
    /// the model put around the trigger word tidied up: "Funktion, Klammer
    /// auf Name, Klammer zu." becomes "Funktion (Name)."
    public static func apply(_ rules: [Replacement], to text: String) -> String {
        let source = text as NSString
        var output = ""
        var cursor = 0
        var quoteIsOpen = false
        // After a line break or a spoken "?" a new sentence starts, but the
        // model wrote what follows in lower case, as the middle of one.
        var capitalizeNext = false
        func addText(_ piece: String) {
            guard capitalizeNext, let first = piece.firstIndex(where: { !$0.isWhitespace && !"\"„“”‚‘’»«".contains($0) }) else {
                output += piece
                return
            }
            capitalizeNext = false
            output += piece[..<first] + piece[first].uppercased() + piece[piece.index(after: first)...]
        }

        for match in matches(of: rules, in: text) {
            // The tidying after the last match may have eaten into this one
            // (only possible with a trigger that starts with punctuation).
            guard match.range.location >= cursor else { continue }
            addText(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            var after = match.range.location + match.range.length
            let written = match.rule.written

            switch Kind(written, quoteIsOpen: &quoteIsOpen) {
            case .opener:
                output.trimTrailing(" ,")
                if !output.isEmpty && !output.hasSuffix("\n") { output += " " }
                output += written
                after = source.skip(" ,", from: after)
            case .closer:
                output.trimTrailing(" ,")
                output += written
            case .punctuation:
                output.trimTrailing(" ,")
                output += written
                after = source.skip(" ,.;:", from: after)
                if after < source.length, !source.hasNewline(at: after) { output += " " }
                capitalizeNext = ".!?".contains(written)
            case .lineBreak:
                output.trimTrailing(" ,")
                output += written
                after = source.skip(" ,.;:", from: after)
                capitalizeNext = true
            case .plain:
                output += written
                capitalizeNext = false
            }
            cursor = after
        }
        addText(source.substring(from: cursor))
        return output
    }

    // MARK: - Matching

    struct Match {
        let range: NSRange
        let rule: Replacement
    }

    /// Every place a rule matches, left to right, longest phrase first where
    /// two overlap ("neuer Absatz" before a lone "Absatz").
    static func matches(of rules: [Replacement], in text: String) -> [Match] {
        let ordered = rules.filter(\.isOn).sorted { $0.spoken.count > $1.spoken.count }
        var found: [Match] = []
        for rule in ordered {
            guard let regex = pattern(for: rule.spoken) else { continue }
            for result in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let taken = found.contains { NSIntersectionRange($0.range, result.range).length > 0 }
                if !taken { found.append(Match(range: result.range, rule: rule)) }
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Case-insensitive, whole words only. Words may be joined by the commas,
    /// full stops or hyphens a model likes to add ("Klammer, auf"), and a
    /// letter code like "XX" also matches "xx", "x x" and "X. X.".
    static func pattern(for spoken: String) -> NSRegularExpression? {
        let words = spoken.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }

        let body: String
        if words.count == 1, (2 ... 4).contains(words[0].count), words[0].allSatisfy(\.isLetter),
           words[0] == words[0].uppercased() {
            body = words[0].map { NSRegularExpression.escapedPattern(for: String($0)) + "\\.?" }
                .joined(separator: "[\\s\\-]*")
        } else {
            body = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s,.\\-]+")
        }
        return try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]
        )
    }

    /// How a replacement sits in the sentence, which decides the spacing.
    enum Kind {
        case opener, closer, punctuation, lineBreak, plain

        init(_ written: String, quoteIsOpen: inout Bool) {
            switch written {
            case "(", "[", "{": self = .opener
            // German quotes open low and close high: the next “ closes.
            case "„", "‚":
                self = .opener
                quoteIsOpen = true
            case ")", "]", "}": self = .closer
            // The same mark opens and closes, so alternate.
            case "\"", "'", "“", "”", "‘", "’", "«", "»", "‹", "›":
                self = quoteIsOpen ? .closer : .opener
                quoteIsOpen.toggle()
            case ".", ",", ":", ";", "!", "?": self = .punctuation
            default:
                self = written.allSatisfy(\.isNewline) && !written.isEmpty ? .lineBreak : .plain
            }
        }
    }
}

private extension String {
    mutating func trimTrailing(_ characters: String) {
        while let last, characters.contains(last) { removeLast() }
    }
}

private extension NSString {
    func skip(_ characters: String, from index: Int) -> Int {
        var index = index
        let set = CharacterSet(charactersIn: characters)
        while index < length, let scalar = Unicode.Scalar(character(at: index)), set.contains(scalar) {
            index += 1
        }
        return index
    }

    func hasNewline(at index: Int) -> Bool {
        guard index < length, let scalar = Unicode.Scalar(character(at: index)) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}
