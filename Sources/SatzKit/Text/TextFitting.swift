import Foundation
import NaturalLanguage

/// Makes a transcript sit naturally where it is inserted.
///
/// The model treats every recording as a complete utterance: capital letter
/// at the start, full stop at the end. Inserted mid-sentence that reads
/// "eine Funktion Nur die PDF-Dateien., die". So: spaces where the text
/// around needs them, no full stop before a comma or a lowercase word, and a
/// small first letter where it is safe to know. German capitalises nouns, so
/// there only a short list of function words is lowered.
public enum TextFitting {

    public static func fit(_ transcript: String, into text: NSString, at range: NSRange, markerFollows: Bool) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        let before = previousVisible(in: text, before: range.location)
        let afterIndex = NSMaxRange(range) + (markerFollows ? 1 : 0)
        let after = afterIndex < text.length ? Character(UnicodeScalar(text.character(at: afterIndex)) ?? " ") : nil

        let midSentence = before.map { !".!?…:\n".contains($0) } ?? false
        if midSentence { result = lowerFirstWordIfSafe(result, context: text as String) }

        let next = nextVisible(in: text, from: afterIndex)
        let continues = next.map { $0.isLowercase || ",;:)".contains($0) } ?? false
        if continues, result.hasSuffix("."), !result.hasSuffix("..") {
            result.removeLast()
        }

        if range.location > 0 {
            let previous = Character(UnicodeScalar(text.character(at: range.location - 1)) ?? " ")
            if !previous.isWhitespace, !"([{„\"“".contains(previous) { result = " " + result }
        }
        if let after, after.isLetter || after.isNumber { result += " " }
        return result
    }

    /// The first character from `location` on that is not a space.
    private static func nextVisible(in text: NSString, from location: Int) -> Character? {
        var index = location
        while index < text.length {
            let character = Character(UnicodeScalar(text.character(at: index)) ?? " ")
            if character == "\n" || !character.isWhitespace { return character }
            index += 1
        }
        return nil
    }

    /// The last character before `location` that is not a space.
    private static func previousVisible(in text: NSString, before location: Int) -> Character? {
        var index = location - 1
        while index >= 0 {
            let character = Character(UnicodeScalar(text.character(at: index)) ?? " ")
            if character == "\n" { return character }
            if !character.isWhitespace { return character }
            index -= 1
        }
        return nil
    }

    /// - Parameter context: the text around it. A few words alone are too
    ///   little to tell German from English.
    static func lowerFirstWordIfSafe(_ text: String, context: String = "") -> String {
        guard let first = text.split(separator: " ", maxSplits: 1).first.map(String.init),
              let initial = first.first, initial.isUppercase else { return text }
        // Acronyms and "I" stay as they are.
        let letters = first.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased() { return text }
        if first == "I" || first.hasPrefix("I'") { return text }

        let lowered = first.lowercased()
        let english = NLLanguageRecognizer.dominantLanguage(for: context + " " + text) == .english
        guard english || germanFunctionWords.contains(lowered.trimmingCharacters(in: .punctuationCharacters)) else {
            return text
        }
        return String(lowered.prefix(1)) + String(text.dropFirst(1))
    }

    /// Words that are never capitalised mid-sentence in German.
    static let germanFunctionWords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "und", "oder", "aber", "denn", "sondern", "doch", "nur", "auch", "noch", "schon", "sehr",
        "mit", "von", "zu", "zum", "zur", "für", "auf", "in", "im", "an", "am", "bei", "beim", "nach",
        "vor", "über", "unter", "ohne", "um", "durch", "gegen", "aus", "seit", "bis", "wie", "als",
        "wenn", "dass", "weil", "ob", "damit", "also", "dann", "nicht", "kein", "keine", "so",
        "ich", "du", "er", "sie", "es", "wir", "ihr", "man", "mir", "mich", "dir", "dich", "uns",
        "bitte", "vielleicht", "etwa", "ganz", "mal", "hier", "dort", "da", "jetzt", "immer",
    ]
}
