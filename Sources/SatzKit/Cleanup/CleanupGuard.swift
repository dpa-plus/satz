import Foundation

/// Whether a model's answer still looks like the text that was dictated.
///
/// Models answer a dictated question ("Die Hauptstadt von Australien ist
/// Canberra."), tell the joke they were asked for, translate, or write the
/// mail the dictation was about. All of those share few words with what was
/// said, or many more words than were said. Calibrated on about 1,400 real
/// answers: the share rule rejected every one of those and no good answer
/// (`Tests/Fixtures/cleanup-guard-cases.json`). The same rule runs on Windows
/// and Linux (`desktop/src/core/cleanup.ts`); the reference is the tested
/// `guard2.py`.
///
/// A share of words cannot tell "do not send" from "do send", or 1000 from
/// 9000, so checks on top (Codex CC-2, 14.10.2026, v3): no number appears
/// that was not said (a number said in words may come back in digits, but
/// only as its own value), the negations are exactly those said, and "Nur
/// Zeichensetzung", which promises that every word stays, keeps every word in
/// its place. Codex's fourth audit (R4, v4) added two more: a sign belongs to
/// its number ("-1000" is not "1000", "minus zwanzig" is -20), and a dictation
/// of a word or two keeps every word it had ("nein danke" is not "Danke.").
/// These do reject some good answers (the fixture's "ok danke" to "Okay,
/// danke."); the cost is the cleanup only, the dictation is pasted as it was
/// said.
public enum CleanupGuard {

    /// Said, but not words worth keeping.
    static let fillers: Set<String> = ["äh", "ähm", "öh", "öhm", "hm", "hmm", "mhm", "um", "uh", "uhm", "erm", "ah"]

    /// Words that turn a sentence around. "nein" and "no" are not among them:
    /// they are how people correct themselves ("Montag, nein, Dienstag"), and
    /// the correction is meant to drop what came before.
    static let negations: Set<Word> = Set([
        "nicht", "kein", "keine", "keinen", "keinem", "keiner", "keines", "nie", "niemals", "nichts", "niemand", "nirgends", "weder",
        "not", "never", "nothing", "nobody", "nowhere", "neither", "nor", "cannot",
        // The contractions without their apostrophe, the way speech
        // recognition writes them ("i dont think so"): a model adds the
        // apostrophe, and the count must not change for that.
        "dont", "cant", "wont", "isnt", "arent", "wasnt", "werent", "doesnt", "didnt", "hasnt", "havent", "hadnt", "wouldnt", "couldnt", "shouldnt",
        "mustnt", "neednt", "aint",
    ].map { Array($0.unicodeScalars) })

    /// What stands where a contraction has its apostrophe: ' ’ ‘ ` ´ (a model
    /// writes the typographic one, speech recognition the plain one). Not ʼ
    /// (U+02BC): that is a letter, so "donʼt" is one word (`negationCount`).
    static let apostrophes: Set<Unicode.Scalar> = ["\u{27}", "\u{2019}", "\u{2018}", "\u{60}", "\u{B4}"]

    /// A word as Unicode scalars: lengths and prefixes are counted the way the
    /// reference counts them (code points), not as Swift's characters.
    typealias Word = [Unicode.Scalar]

    /// Whether the answer may be pasted instead of what was dictated. The
    /// user's own prompt only has to give something back: it may ask for a
    /// translation or a summary.
    public static func accepts(_ answer: String, for original: String, level: CleanupLevel, vocabulary: [String] = []) -> Bool {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // The user's own prompt may ask for anything, a translation or a
        // summary: it is not judged by the dictation at all.
        if level == .custom { return true }
        // Whatever the preset: no number that was not said (a number word only
        // as the number it is, a sign with its number), no negation lost or
        // added.
        guard keepsNumbers(original, answer), keepsNegations(original, answer) else { return false }
        // "Every word stays": the same words in the same places, so no word
        // added, dropped, merged, moved or said fewer times. Only a spelling
        // fix may differ, or a word of the vocabulary. The words never see a
        // "-" (they are letters and digits), so the signs are held to the
        // same places on their own. No shares to read, so this returns before
        // the limits below.
        if level == .punctuation {
            return keepsSigns(original, answer)
                && sameWordsInOrder(strictWords(original), strictWords(answer), vocabulary: Set(vocabulary.flatMap { strictWords($0) }))
        }
        // Every level left has limits; one that gets none is not let through.
        guard let limits = level.guardLimits else { return false }
        let said = words(original)
        let out = words(answer)
        let fillerWords = Set(fillers.map { Array($0.unicodeScalars) })
        let kept = said.filter { !fillerWords.contains($0) }
        let vocabularyWords = Set(vocabulary.flatMap { words($0) })
        // A word or two: no share means much. Only a long answer gives away
        // that it is no longer the dictation ("ja" became a paragraph), and
        // no word may be one that was not said ("nein danke" became "Ja
        // bitte"); a word of the vocabulary is the name the transcription
        // misheard. The answer keeps a word, too: "ja gerne" must not become
        // a thumbs-up. And (v4) it keeps every word that was said: "nein
        // danke" must not become "Danke.", the denial would be gone and
        // nothing else in the answer is wrong. Digits are no word to find: the
        // number rule has judged every number of the answer ("tausend Euro"
        // and "1.000 Euro"), unless some are list markers, which it leaves
        // out and which stay words.
        if kept.count < 3 {
            if !said.isEmpty, out.isEmpty { return false }
            let judged = numberRuns(answer).count == numberRuns(answer, dropListMarkers: true).count
            return out.count <= kept.count + 4 && out.allSatisfy { word in
                (judged && word.allSatisfy(isDigitScalar)) || said.contains { vocabularyWords.contains(word) || similar(word, $0) }
            } && keepsEveryWord(said, answer: answer, out: out, fillers: fillerWords, vocabulary: vocabularyWords)
        }
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

    /// Lowercased, with the Greek final sigma written as the plain one:
    /// JavaScript lowercases "ΣΑΣ" to "σας" and Swift to "σασ", and the two
    /// must call the same words the same.
    static func lowered(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{3C2}", with: "\u{3C3}")
    }

    /// The runs of letters and digits in the lowercased text.
    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var current: Word = []
        for scalar in lowered(text).unicodeScalars {
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

    // MARK: - What must survive

    /// Decimal digits in any script.
    static func isDigitScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .decimalNumber
    }

    /// Between the groups of a number: 1.000, 2,500, 1'000, 1’000, 1 000 and 1<thin space>000.
    static let groupSeparators: Set<Unicode.Scalar> = [".", ",", "\u{27}", "\u{2019}", " ", "\u{2009}"]

    /// What ends a line: the ones `Character.isNewline` knows, so the
    /// TypeScript side (`isBreak`) says the same.
    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    /// What stands for a minus in front of a number: "-", the real minus "−"
    /// (U+2212) and the en dash "–" (U+2013), as a keyboard, a typesetter and
    /// a model write it.
    static let minusSigns: Set<Unicode.Scalar> = ["-", "\u{2212}", "\u{2013}"]

    /// The one space that may stand between a sign and its digits ("- 5"): the
    /// plain one, the no-break one and the thin ones.
    static let signGaps: Set<Unicode.Scalar> = [" ", "\u{A0}", "\u{2009}", "\u{202F}"]

    /// "-" or "+" when the digits that start at `start` have a sign, else nil
    /// (v4, Codex R4: the sign was dropped, and "-1000" became "1000"). A sign
    /// is "-", "−", "–" or "+" right in front of the digits (one space may
    /// stand between), with no letter or digit in front of it: "Seite 3-5"
    /// and "A-1" are a range and a code. Or the word "minus" or "plus" is the
    /// word before the digits ("minus 20"; not "minus20", that is one word).
    /// A real sign wins over the word. `scalars` are lowercase.
    private static func signBefore(_ scalars: [Unicode.Scalar], digitsAt start: Int) -> Unicode.Scalar? {
        var at = start - 1
        if at >= 0, signGaps.contains(scalars[at]) { at -= 1 }
        if at >= 0, minusSigns.contains(scalars[at]) || scalars[at] == "+" {
            if at > 0, isWordScalar(scalars[at - 1]) { return nil }
            return scalars[at] == "+" ? "+" : "-"
        }
        // The word before: something that is no letter or digit in between,
        // and the word ends there.
        var end = start - 1
        guard end >= 0, !isWordScalar(scalars[end]) else { return nil }
        while end >= 0, !isWordScalar(scalars[end]) { end -= 1 }
        guard end >= 0 else { return nil }
        var begin = end
        while begin > 0, isWordScalar(scalars[begin - 1]) { begin -= 1 }
        let before = Array(scalars[begin ... end])
        if before == minus { return "-" }
        if before == plus { return "+" }
        return nil
    }

    /// The numbers in a text, in order: runs of decimal digits in any script
    /// ("3,5" has two: 3 and 5), with a thousands separator and exactly three
    /// more digits (again and again) read as one number: "1.000", "2,500" and
    /// "1 000 000" are 1000, 2500 and 1000000. A number with a sign (see
    /// `signBefore`) starts with "-" or "+", whichever way it was written:
    /// "−1.000" and "minus 1000" are "-1000". In the answer
    /// (`dropListMarkers`) a number at the start of a line, after spaces,
    /// directly followed by "." or ")" is a list marker ("1. Milch"), not a
    /// number, and is left out.
    static func numberRuns(_ text: String, dropListMarkers: Bool = false) -> [Word] {
        // Lowercase, for the words "minus" and "plus" (digits have no case).
        let scalars = Array(lowered(text).unicodeScalars)
        var result: [Word] = []
        // Nothing but spaces and tabs since the line began.
        var atLineStart = true
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard isDigitScalar(scalar) else {
                if isLineBreak(scalar) {
                    atLineStart = true
                } else if scalar != " ", scalar != "\t" {
                    atLineStart = false
                }
                i += 1
                continue
            }
            let startsLine = atLineStart
            atLineStart = false
            var number: Word = signBefore(scalars, digitsAt: i).map { [$0] } ?? []
            while i < scalars.count, isDigitScalar(scalars[i]) { number.append(scalars[i]); i += 1 }
            // A separator and exactly three digits: a group of the same number.
            while i + 3 < scalars.count, groupSeparators.contains(scalars[i]),
                  isDigitScalar(scalars[i + 1]), isDigitScalar(scalars[i + 2]), isDigitScalar(scalars[i + 3]),
                  !(i + 4 < scalars.count && isDigitScalar(scalars[i + 4])) {
                number.append(contentsOf: scalars[i + 1 ... i + 3])
                i += 4
            }
            let marker = dropListMarkers && startsLine && i < scalars.count && (scalars[i] == "." || scalars[i] == ")")
            if !marker { result.append(number) }
        }
        return result
    }

    /// The sign a number from `numberRuns` carries: "-", "+" or nil.
    static func signOf(_ run: Word) -> Unicode.Scalar? {
        guard let first = run.first, first == "-" || first == "+" else { return nil }
        return first
    }

    /// The digits of a number from `numberRuns`, without its sign.
    static func unsigned(_ run: Word) -> Word {
        signOf(run) == nil ? run : Array(run.dropFirst())
    }

    /// The distinct numbers in a text (`numberRuns`).
    static func digitRuns(_ text: String) -> Set<Word> {
        Set(numberRuns(text))
    }

    /// ä ö ü ß written the way a keyboard without them writes them.
    static func folded(_ word: Word) -> Word {
        var result: Word = []
        for scalar in word {
            switch scalar.value {
            case 0xE4: result.append(contentsOf: ["a", "e"])
            case 0xF6: result.append(contentsOf: ["o", "e"])
            case 0xFC: result.append(contentsOf: ["u", "e"])
            case 0xDF: result.append(contentsOf: ["s", "s"])
            default: result.append(scalar)
            }
        }
        return result
    }

    // MARK: - Number words

    private static func word(_ text: String) -> Word { Array(text.unicodeScalars) }
    private static func table(_ entries: KeyValuePairs<String, Int>) -> [Word: Int] {
        Dictionary(uniqueKeysWithValues: entries.map { (word($0.key), $0.value) })
    }
    private static func hasSuffix(_ word: Word, _ suffix: Word) -> Bool {
        word.count >= suffix.count && Array(word.suffix(suffix.count)) == suffix
    }
    private static func index(of needle: Word, in word: Word) -> Int? {
        guard word.count >= needle.count else { return nil }
        return (0 ... word.count - needle.count).first { Array(word[$0 ..< $0 + needle.count]) == needle }
    }

    // The tables are folded (fuenf, zwoelf, dreissig): `folded` runs first.

    /// One to nine as the front of a compound: ein in einhundert, einundzwanzig, eintausend.
    static let germanUnits = table(["ein": 1, "zwei": 2, "drei": 3, "vier": 4, "fuenf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9])
    static let germanTeens = table(["zehn": 10, "elf": 11, "zwoelf": 12, "dreizehn": 13, "vierzehn": 14, "fuenfzehn": 15, "sechzehn": 16, "siebzehn": 17,
                                    "achtzehn": 18, "neunzehn": 19])
    static let germanTens = table(["zwanzig": 20, "dreissig": 30, "vierzig": 40, "fuenfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90])
    /// Words that are a number only as a word of their own; behind hundert or
    /// tausend only "eins" is one, in front of them only "ein".
    static let germanAlone = table(["null": 0, "ein": 1, "eins": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1])
    static let englishCardinals = table([
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000,
    ])
    static let englishOrdinals = table([
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1000,
    ])
    /// The last part of a German ordinal and the cardinal it is made from
    /// (erst from eins, dritt from drei, zwanzigst from zwanzig). What stands
    /// in front is a cardinal's front: dreizehnt is drei + zehnt,
    /// einundzwanzigst is einund + zwanzigst, zweihundertst is zwei + hundertst.
    static let germanOrdinalParts: [(ordinal: Word, cardinal: Word)] = [
        ("erst", "eins"), ("zweit", "zwei"), ("dritt", "drei"), ("viert", "vier"), ("fuenft", "fuenf"), ("sechst", "sechs"), ("siebt", "sieben"),
        ("acht", "acht"), ("neunt", "neun"), ("zehnt", "zehn"), ("elft", "elf"), ("zwoelft", "zwoelf"),
        ("zwanzigst", "zwanzig"), ("dreissigst", "dreissig"), ("vierzigst", "vierzig"), ("fuenfzigst", "fuenfzig"), ("sechzigst", "sechzig"),
        ("siebzigst", "siebzig"), ("achtzigst", "achtzig"), ("neunzigst", "neunzig"), ("hundertst", "hundert"), ("tausendst", "tausend"),
    ].map { (word($0.0), word($0.1)) }
    static let germanOrdinalEndings = ["e", "en", "er", "es", "em"].map(word)
    private static let und = word("und"), hundert = word("hundert"), tausend = word("tausend"), ein = word("ein"), eins = word("eins")
    private static let millions: Set<Word> = [word("million"), word("millionen")]
    private static let minus = word("minus"), plus = word("plus")

    /// 1 to 99 written as one word. `one` is the form of 1 that may stand
    /// here: "eins" behind hundert and tausend ("hunderteins"), "ein" in
    /// front of them ("einhundertein" + "tausend").
    private static func germanBelow100(_ w: Word, one: Word) -> Int? {
        if w == one { return 1 }
        if let value = germanUnits[w], value > 1 { return value }
        if let value = germanTeens[w] ?? germanTens[w] { return value }
        // einundzwanzig, neunundneunzig: a unit, "und", a ten.
        for (unit, value) in germanUnits {
            let front = unit + und
            if w.count > front.count, w.starts(with: front), let tens = germanTens[Array(w.dropFirst(front.count))] { return value + tens }
        }
        return nil
    }

    /// 1 to 999: dreihundertfuenfzig, hundert, einhundertzwanzig.
    private static func germanBelow1000(_ w: Word, one: Word) -> Int? {
        guard !w.isEmpty else { return nil }
        guard let at = index(of: hundert, in: w) else { return germanBelow100(w, one: one) }
        let head = Array(w[..<at]), tail = Array(w[(at + hundert.count)...])
        guard let times = head.isEmpty ? 1 : germanUnits[head] else { return nil }
        if tail.isEmpty { return times * 100 }
        return germanBelow100(tail, one: one).map { times * 100 + $0 }
    }

    /// A German cardinal written as one word, 0 to 999,999 (`w` is folded).
    static func germanCardinal(_ w: Word) -> Int? {
        if let value = germanAlone[w] { return value }
        guard let at = index(of: tausend, in: w) else { return germanBelow1000(w, one: eins) }
        let head = Array(w[..<at]), tail = Array(w[(at + tausend.count)...])
        guard let thousands = head.isEmpty ? 1 : germanBelow1000(head, one: ein) else { return nil }
        if tail.isEmpty { return thousands * 1000 }
        return germanBelow1000(tail, one: eins).map { thousands * 1000 + $0 }
    }

    /// "fuenften", "zweite", "einundzwanzigste": an ordinal's stem and one of
    /// the endings e en er es em (`w` is folded). Without an ending it is no
    /// ordinal: "erst" is "only".
    static func germanOrdinal(_ w: Word) -> Int? {
        for ending in germanOrdinalEndings where w.count > ending.count && hasSuffix(w, ending) {
            let stem = Array(w.dropLast(ending.count))
            for part in germanOrdinalParts where hasSuffix(stem, part.ordinal) {
                if let value = germanCardinal(Array(stem.dropLast(part.ordinal.count)) + part.cardinal) { return value }
            }
        }
        return nil
    }

    /// The value of a cardinal written as one word, German or English: drei 3,
    /// einundzwanzig 21, dreihundertfuenfzig 350, zweitausendfuenfhundert 2500,
    /// twelve 12, hundred 100. nil for any other word.
    static func cardinalValue(_ word: Word) -> Int? {
        let plain = folded(word)
        return englishCardinals[plain] ?? germanCardinal(plain)
    }

    /// The value of a number written as one word: a cardinal (`cardinalValue`) or
    /// an ordinal (fuenften 5, third 3, twentieth 20). nil for any other word,
    /// and for "halb" and "half": half of what is not a number.
    static func numberWordValue(_ word: Word) -> Int? {
        let plain = folded(word)
        return englishCardinals[plain] ?? englishOrdinals[plain] ?? germanCardinal(plain) ?? germanOrdinal(plain)
    }

    /// A number word of a dictation: where it stands, what it is worth and
    /// the sign the word in front of it gave it ("minus zwanzig" is -20).
    struct NumberWord: Equatable {
        let position: Int
        let value: Int
        /// "", "-" or "+".
        let sign: String
        /// The number as the digits of an answer write it: "20", "-20", "+3".
        var written: String { sign + String(value) }
    }

    /// The number words of a dictation, one entry per word. "million" and
    /// "millionen" count only behind a cardinal ("zwei millionen" is
    /// 2000000, as well as the "zwei" in it); a digit in front of them is not
    /// read ("1,5 Millionen" would come out as 5). A word has a sign when the
    /// word right before it is "minus" or "plus"; a million has the sign of
    /// the cardinal in front of it ("minus zwei millionen" is -2000000).
    static func numberWords(_ words: [Word]) -> [NumberWord] {
        func sign(before position: Int) -> String {
            guard position > 0 else { return "" }
            return words[position - 1] == minus ? "-" : words[position - 1] == plus ? "+" : ""
        }
        var entries: [NumberWord] = []
        for (position, word) in words.enumerated() {
            if millions.contains(word) {
                if position > 0, let times = cardinalValue(words[position - 1]), (1 ... 999).contains(times) {
                    entries.append(NumberWord(position: position, value: times * 1_000_000, sign: sign(before: position - 1)))
                }
            } else if let value = numberWordValue(word) {
                entries.append(NumberWord(position: position, value: value, sign: sign(before: position)))
            }
        }
        return entries
    }

    /// What the number words of a dictation are worth, without their signs.
    static func numberWordValues(_ words: [Word]) -> [Int] {
        numberWords(words).map(\.value)
    }

    /// A number from `numberRuns` as a value without leading zeros ("07" is
    /// "7", "-07" is "-7"); nil unless it is all ASCII digits (the digits of
    /// other scripts have no number word). The sign stays: it is part of what
    /// the number is.
    private static func plainValue(_ run: Word) -> String? {
        let digits = unsigned(run)
        guard !digits.isEmpty, digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return nil }
        let trimmed = digits.drop { $0 == "0" }
        return (signOf(run).map { String($0) } ?? "") + (trimmed.isEmpty ? "0" : String(String.UnicodeScalarView(trimmed)))
    }

    /// No number in the answer that was not said. A number may disappear ("um
    /// 3, nein, um 4" drops the 3) but never appear or change: 12345678 must
    /// not become 12345679, which the spelling rule in `similar` would let
    /// through. A number said in words may come back in digits ("drei
    /// Exemplare" and "3 Exemplare"), but only as the number it is: each new
    /// number in the answer needs a number word of the dictation with exactly
    /// that value, each word used once (`numberWords`). "um drei" may not
    /// become "um 15 Uhr", and "ein Kunde zahlt 1000 Euro" not "9000".
    ///
    /// The sign is part of the number (v4, Codex R4): "-1000" and "1000" are
    /// two numbers, "minus zwanzig" is "-20" and not "20", and "+49" is not
    /// "49". The dropped sign of a saldo or a temperature changed what was
    /// said and the digits looked the same.
    static func keepsNumbers(_ original: String, _ answer: String) -> Bool {
        let said = digitRuns(original)
        let added = numberRuns(answer, dropListMarkers: true).filter { !said.contains($0) }
        guard !added.isEmpty else { return true }
        var unused = numberWords(words(original)).map(\.written)
        for run in added {
            guard let value = plainValue(run), let match = unused.firstIndex(of: value) else { return false }
            unused.remove(at: match)
        }
        return true
    }

    /// Every number keeps its sign, in its place. "Nur Zeichensetzung" keeps
    /// every word, but a "-" is no word (the words are letters and digits):
    /// "der Saldo ist -1000" and "der Saldo ist 1000" have the same words. The
    /// other presets cannot tell either where a number is said twice, once
    /// with a sign and once without: they judge the set of numbers. The signs
    /// are compared one for one when the answer has as many numbers as the
    /// dictation; if it has not, a number was regrouped or the word list
    /// stood in for it, which the words have judged already and which is no
    /// sign lost.
    static func keepsSigns(_ original: String, _ answer: String) -> Bool {
        let said = numberRuns(original).map(signOf), kept = numberRuns(answer).map(signOf)
        return said.count != kept.count || said == kept
    }

    /// A dictation of a word or two keeps every word it had (v4, Codex R4):
    /// "nein danke" became "Danke." and the denial was gone, every word of the
    /// answer being one that was said. A word is still there when the answer
    /// has it, or one `similar`. A number comes back as digits: "tausend" as
    /// 1000, "minus zwanzig" as -20 (the "minus" is in the sign), "zwei
    /// millionen" as 2000000, "1000" as "1.000"; a digit word of the dictation
    /// needs its digits in a number of the answer. A word that is gone needs a
    /// vocabulary word of its own in the answer that the dictation did not say
    /// itself (the transcription misheard a name: "yannick" and "Jannik"; a
    /// name that was said stands for nothing else, so "ja jannik" does not
    /// become "Jannik."). Fillers are no words. `said` are all the words said,
    /// fillers too.
    static func keepsEveryWord(_ said: [Word], answer: String, out: [Word], fillers: Set<Word>, vocabulary: Set<Word>) -> Bool {
        let runs = numberRuns(answer, dropListMarkers: true)
        let written = Set(runs.compactMap(plainValue))
        let digitsOfAnswer = runs.map(unsigned)
        let entries = Dictionary(uniqueKeysWithValues: numberWords(said).map { ($0.position, $0) })
        func isNumeral(_ word: Word) -> Bool { !word.isEmpty && word.allSatisfy(isDigitScalar) }
        /// What a number word can come back as: its value, and for a cardinal
        /// in front of "million" the million as well.
        func values(at position: Int) -> [String] {
            var result = entries[position].map { [$0.written] } ?? []
            if position + 1 < said.count, millions.contains(said[position + 1]), let million = entries[position + 1] { result.append(million.written) }
            return result
        }
        let standIns = out.filter { vocabulary.contains($0) && !said.contains($0) }.count
        var gone = 0
        for (position, word) in said.enumerated() where !fillers.contains(word) {
            if isNumeral(word) {
                guard out.contains(word) || digitsOfAnswer.contains(where: { index(of: word, in: $0) != nil }) else { return false }
                continue
            }
            if out.contains(where: { similar(word, $0) }) { continue }
            // A number word, or the "minus" in front of one, comes back as
            // the number; nothing else stands for it.
            var comesBack = values(at: position)
            if (word == minus || word == plus), position + 1 < said.count {
                let next = said[position + 1]
                if isNumeral(next) {
                    comesBack = [plainValue([word == minus ? "-" : "+"] + next)].compactMap { $0 }
                } else {
                    comesBack = values(at: position + 1)
                }
            }
            if !comesBack.isEmpty {
                guard comesBack.contains(where: written.contains) else { return false }
                continue
            }
            gone += 1
        }
        return gone <= standIns
    }

    /// The strong negations in a text, a contraction like "don't" counted once.
    static func negationCount(_ text: String) -> Int {
        let scalars = Array(lowered(text).unicodeScalars)
        var count = 0
        // Where the last word ended and its last letter: "don" + "'" + "t".
        var previousEnd = -1
        var previousLast: Unicode.Scalar = " "
        var index = 0
        while index < scalars.count {
            guard isWordScalar(scalars[index]) else { index += 1; continue }
            let start = index
            while index < scalars.count, isWordScalar(scalars[index]) { index += 1 }
            let word = Array(scalars[start ..< index])
            if negations.contains(word) {
                count += 1
            } else if word.count >= 3, Array(word.suffix(3)) == ["n", "\u{2BC}", "t"] {
                // "donʼt" with the letter ʼ is one word.
                count += 1
            } else if word.count == 1, word[0] == "t", start >= 1, apostrophes.contains(scalars[start - 1]),
                      previousEnd == start - 1, previousLast == "n" {
                // "n't": don't, won't, isn't, can't.
                count += 1
            }
            previousEnd = index
            previousLast = scalars[index - 1]
        }
        return count
    }

    /// The answer says "not" exactly as often as the dictation did: one lost
    /// turns "do not send" into "do send", and one added turns "ich komme
    /// morgen" into "ich komme morgen nicht".
    static func keepsNegations(_ original: String, _ answer: String) -> Bool {
        negationCount(answer) == negationCount(original)
    }

    /// An obvious spelling fix: the same word, or both at least four letters
    /// long, without digits, and one letter apart (one added, dropped or
    /// changed, or two neighbours swapped as in "tset" and "test").
    static func spellingFix(_ a: Word, _ b: Word) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        guard !a.contains(where: isDigitScalar), !b.contains(where: isDigitScalar) else { return false }
        return oneEditApart(a, b) || neighboursSwapped(a, b)
    }

    /// The same letters but for one pair of neighbours in the other order.
    static func neighboursSwapped(_ a: Word, _ b: Word) -> Bool {
        guard a.count == b.count, let first = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else { return false }
        guard first + 1 < a.count, a[first] == b[first + 1], a[first + 1] == b[first] else { return false }
        return a[(first + 2)...] == b[(first + 2)...]
    }

    /// What stands inside a word where a contraction or a name has its
    /// apostrophe: ' ’ ʼ ` ´ (not the opening quote ‘).
    static let wordApostrophes: Set<Unicode.Scalar> = ["\u{27}", "\u{2019}", "\u{2BC}", "\u{60}", "\u{B4}"]

    /// The words of "Nur Zeichensetzung", compared one for one: an apostrophe
    /// between two letters is dropped ("geht's" is "gehts", "don't" is
    /// "dont") and ä ö ü ß are written as ae oe ue ss ("uebersehen" is
    /// "übersehen"), so a model may add the one and fix the other without
    /// changing a word.
    static func strictWords(_ text: String) -> [Word] {
        let scalars = Array(lowered(text).unicodeScalars)
        var result: [Word] = []
        var current: Word = []
        for (index, scalar) in scalars.enumerated() {
            if wordApostrophes.contains(scalar), index > 0, index < scalars.count - 1,
               isWordScalar(scalars[index - 1]), isWordScalar(scalars[index + 1]) {
                continue
            }
            if isWordScalar(scalar) {
                current.append(contentsOf: folded([scalar]))
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Word for word the same, give or take a spelling fix each, or a word of
    /// the vocabulary (the transcription misheard a name: "yannick" became
    /// "Jannik").
    static func sameWordsInOrder(_ said: [Word], _ out: [Word], vocabulary: Set<Word>) -> Bool {
        said.count == out.count && zip(said, out).allSatisfy { spellingFix($0, $1) || vocabulary.contains($1) }
    }
}
