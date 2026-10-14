import Foundation

/// Whether a model's answer still looks like the text that was dictated.
///
/// Models answer a dictated question ("Die Hauptstadt von Australien ist
/// Canberra."), tell the joke they were asked for, translate, or write the
/// mail the dictation was about. All of those share few words with what was
/// said, or many more words than were said. Calibrated on about 1,400 real
/// answers: it rejected every one of those and no good answer
/// (`Tests/Fixtures/cleanup-guard-cases.json`). The same rule runs on Windows
/// and Linux; the reference is the tested `guard2.py`.
public enum CleanupGuard {

    /// Said, but not words worth keeping.
    static let fillers: Set<String> = ["äh", "ähm", "öh", "öhm", "hm", "hmm", "mhm", "um", "uh", "uhm", "erm", "ah"]

    /// A word as Unicode scalars: lengths and prefixes are counted the way the
    /// reference counts them (code points), not as Swift's characters.
    typealias Word = [Unicode.Scalar]

    /// Whether the answer may be pasted instead of what was dictated. The
    /// user's own prompt only has to give something back: it may ask for a
    /// translation or a summary.
    public static func accepts(_ answer: String, for original: String, level: CleanupLevel, vocabulary: [String] = []) -> Bool {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let limits = level.guardLimits else { return true }
        let said = words(original)
        let out = words(answer)
        let fillerWords = Set(fillers.map { Array($0.unicodeScalars) })
        let kept = said.filter { !fillerWords.contains($0) }
        let vocabularyWords = Set(vocabulary.flatMap { words($0) })
        // A word or two: no share means much. Only a long answer gives away
        // that it is no longer the dictation ("ja" became a paragraph).
        if kept.count < 3 { return out.count <= kept.count + 4 }
        // Fillers count among what was said: "Ähm," kept at "Nur Zeichensetzung" is fine.
        let outShare = share(out, pool: Set(said), vocabulary: vocabularyWords)
        let inShare = share(kept, pool: Set(out), vocabulary: vocabularyWords)
        let growth = Double(out.count) / Double(kept.count)
        return outShare >= limits.said && inShare >= limits.kept && growth <= limits.growth
    }

    /// Letters and digits in any script; "_" is not one.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    /// The runs of letters and digits in the lowercased text.
    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var current: Word = []
        for scalar in text.lowercased().unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The same word, give or take an ending or a typo: "gefailed" and
    /// "gefailt", "Projekt" and "Projekts".
    static func similar(_ a: Word, _ b: Word) -> Bool {
        if a == b { return true }
        let shortest = min(a.count, b.count)
        guard shortest >= 4 else { return false }
        let k = max(4, shortest - 2)
        return a.starts(with: b.prefix(k)) || b.starts(with: a.prefix(k)) || oneEditApart(a, b)
    }

    /// Levenshtein distance of at most one.
    static func oneEditApart(_ a: Word, _ b: Word) -> Bool {
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count { return zip(a, b).filter { $0 != $1 }.count <= 1 }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        for index in long.indices {
            var shorter = long
            shorter.remove(at: index)
            if shorter == short { return true }
        }
        return false
    }

    /// The part of `list` found in `pool` (or in the vocabulary, whose
    /// spellings the model was told to use). 1 for nothing to check.
    static func share(_ list: [Word], pool: Set<Word>, vocabulary: Set<Word>) -> Double {
        guard !list.isEmpty else { return 1 }
        let found = list.filter { word in
            vocabulary.contains(word) || pool.contains(word) || pool.contains { similar(word, $0) }
        }
        return Double(found.count) / Double(list.count)
    }
}
