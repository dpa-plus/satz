import Foundation
import Testing
@testable import SatzKit

// Codex's third audit, CC-2 (14.10.2026): "Nur Zeichensetzung" promises that
// every word stays, and the guard let "do not send" become "do send", 1000
// become 9000 and three repetitions become one, because it counted a share of
// the words and read 1000 and 9000 as a spelling mistake.
//
// The rules (the same ones run in desktop/test/codexR3CleanupGuard.test.ts):
//  1. "Nur Zeichensetzung": the words of the answer are the words of the
//     dictation, in order. Only an obvious spelling fix may differ (v3:
//     apostrophes inside words and ä ö ü ß are not changes, and a word of the
//     vocabulary may stand for a misheard name).
//  2. Every preset: no number in the answer that was not in the dictation
//     (v3: 1.000 is 1000, a list marker is no number, and a number said in
//     words may come back in digits, but only as its own value, each number
//     word once: "um drei" is not "um 15 Uhr"; v4: the sign is part of the
//     number, "-1000" is not "1000", "minus zwanzig" is -20).
//  3. Every preset: exactly as many strong negations as the dictation had,
//     not fewer and (v3) not more.
//  4. A dictation of fewer than three words (fillers aside): every word of the
//     answer is the same as one that was said, and (v3) the answer keeps a
//     word, and (v4) every word that was said is still there: "nein danke" is
//     not "Danke.".

private func job(_ level: CleanupLevel) -> CleanupJob {
    CleanupJob(provider: .apple, model: CleanupCatalog.model(CleanupProvider.apple.defaultModel, for: .apple),
               address: "", key: "test-key-not-real", level: level)
}

private func accepts(_ answer: String, _ said: String, _ level: CleanupLevel, vocabulary: [String] = []) -> Bool {
    CleanupGuard.accepts(answer, for: said, level: level, vocabulary: vocabulary)
}

private func text(_ word: CleanupGuard.Word) -> String { String(String.UnicodeScalarView(word)) }
private func numbers(_ text: String, markers: Bool = false) -> [String] {
    CleanupGuard.numberRuns(text, dropListMarkers: markers).map { String(String.UnicodeScalarView($0)) }
}
private func strict(_ text: String) -> [String] { CleanupGuard.strictWords(text).map { String(String.UnicodeScalarView($0)) } }
private func value(_ word: String) -> Int? { CleanupGuard.numberWordValue(Array(word.unicodeScalars)) }
private func values(_ text: String) -> [Int] { CleanupGuard.numberWordValues(CleanupGuard.words(text)) }

/// What the audit fed both guards, and a few more of the same kind.
private let meaningChanged: [(said: String, answer: String, why: String)] = [
    ("ich möchte die rechnung morgen nicht überweisen", "Ich möchte die Rechnung morgen überweisen.", "nicht dropped"),
    ("bitte überweise 1000 euro an max", "Bitte überweise 9000 Euro an Max.", "1000 became 9000"),
    ("nein danke", "Ja bitte.", "a short answer reversed"),
    ("bitte nicht senden bitte nicht senden bitte nicht senden", "Bitte nicht senden.", "repetitions dropped"),
    ("please do not send 1000 euros to the customer tomorrow", "Please do send 1000 euros to the customer tomorrow.", "not dropped"),
    ("die nummer ist 12345678", "Die Nummer ist 12345679.", "12345678 became 12345679"),
    ("不要发送", "请发送", "one word without spaces, changed"),
]

@Suite struct CodexR3CleanupGuardTests {

    // MARK: - What the audit reported

    @Test(arguments: CleanupLevel.presets)
    func theReportedAnswersAreRejected(level: CleanupLevel) {
        for item in meaningChanged {
            // "bitte nicht senden" x3 only loses words at the strict preset;
            // at the others it loses a negation, which every preset counts.
            #expect(!accepts(item.answer, item.said, level), "\(level) \(item.why)")
        }
    }

    @Test func theOwnPromptStillMayAnswerAnything() {
        for item in meaningChanged { #expect(accepts(item.answer, item.said, .custom), "\(item.why)") }
        #expect(!accepts("  ", "nein danke", .custom))
    }

    @Test(arguments: CleanupLevel.presets)
    func rightPunctuationStillPasses(level: CleanupLevel) {
        #expect(accepts("Ich möchte die Rechnung morgen nicht überweisen.", "ich möchte die rechnung morgen nicht überweisen", level))
        #expect(accepts("Bitte überweise 1000 Euro an Max.", "bitte überweise 1000 euro an max", level))
        #expect(accepts("Bitte nicht senden, bitte nicht senden, bitte nicht senden.", "bitte nicht senden bitte nicht senden bitte nicht senden", level))
        #expect(accepts("Please do not send 1000 euros to the customer tomorrow.", "please do not send 1000 euros to the customer tomorrow", level))
        #expect(accepts("Die Nummer ist 12345678.", "die nummer ist 12345678", level))
        #expect(accepts("Nein, danke.", "nein danke", level))
    }

    /// Through the client: the original is pasted, with the reason.
    @Test func theClientPastesTheOriginalInsteadOfTheChangedAnswer() async {
        for item in meaningChanged {
            let result = await CleanupClient(apple: { _ in item.answer }).run(job(.punctuation), text: item.said)
            #expect(result.failure == .rejected && result.text == item.said && result.cleaned == item.answer, "\(item.why)")
        }
        let fine = await CleanupClient(apple: { _ in "Ich möchte die Rechnung morgen nicht überweisen." })
            .run(job(.punctuation), text: "ich möchte die rechnung morgen nicht überweisen")
        #expect(fine.failure == nil && fine.text == "Ich möchte die Rechnung morgen nicht überweisen.")
    }

    // MARK: - 1. Nur Zeichensetzung: every word stays, in order

    @Test func theWordsOfTheAnswerAreTheWordsSaid() {
        let said = "ähm ich komme morgen um 10 uhr"
        #expect(accepts("Ähm, ich komme morgen um 10 Uhr.", said, .punctuation))
        // Fillers are words too.
        #expect(!accepts("Ich komme morgen um 10 Uhr.", said, .punctuation))
        // Added, dropped, merged, moved, repeated.
        #expect(!accepts("Ähm, ich komme morgen alle um 10 Uhr.", said, .punctuation))
        #expect(!accepts("Ähm, ich komme morgen um 10.", said, .punctuation))
        #expect(!accepts("Ähm, ich komme morgen um 10 Uhr, Uhr.", said, .punctuation))
        #expect(!accepts("Ich komme ähm morgen um 10 Uhr.", said, .punctuation))
        #expect(!accepts("Ähm, ich komme morgen um 10Uhr.", said, .punctuation))
        // The same sentence at the next level may lose the filler.
        #expect(accepts("Ich komme morgen um 10 Uhr.", said, .light))
        // A stutter is a word, and stays.
        #expect(!accepts("Wir sind morgen da.", "wir sind sind morgen da", .punctuation))
        #expect(accepts("Wir sind morgen da.", "wir sind sind morgen da", .light))
        // Same words, other order.
        #expect(!accepts("Morgen gehe ich nach Hause.", "ich gehe morgen nach hause", .punctuation))
    }

    @Test func aGreekFinalSigmaIsTheSameLetterOnBothPlatforms() {
        // JavaScript lowercases "ΣΑΣ" to "σας", Swift used to say "σασ".
        #expect(accepts("Σας ευχαριστώ.", "ΣΑΣ ΕΥΧΑΡΙΣΤΩ", .punctuation))
        #expect(CleanupGuard.words("ΣΑΣ σας") == [Array("σασ".unicodeScalars), Array("σασ".unicodeScalars)])
    }

    @Test func onlyAnObviousSpellingFixMayDiffer() {
        // One letter added, dropped, changed, or two neighbours swapped; both words four letters or more, no digits.
        #expect(accepts("Das ist ein Test.", "das ist ein tset", .punctuation))
        #expect(accepts("Das Projekt läuft.", "das projeckt läuft", .punctuation))
        #expect(accepts("Ich mag Hunde.", "ich mag hunnde", .punctuation))
        // Two letters off ("gefailed" and "gefailt" are one thing at the next level, two edits here), or another word.
        #expect(!accepts("Wir testen das gefailt.", "wir testen das gefailed", .punctuation))
        #expect(!accepts("Das ist ein Hund.", "das ist ein haus", .punctuation))
        // Under four letters nothing may change, not even a letter.
        #expect(!accepts("Ich mag das nie.", "ich mag das die", .punctuation))
        #expect(!accepts("Ihr geht.", "ich geht", .punctuation))
        // A word with a digit has to be the same word.
        #expect(!accepts("Das Modell a1235 läuft.", "das modell a1234 läuft", .punctuation))
        #expect(CleanupGuard.spellingFix(Array("tset".unicodeScalars), Array("test".unicodeScalars)))
        #expect(!CleanupGuard.spellingFix(Array("tset".unicodeScalars), Array("tesst1".unicodeScalars)))
        #expect(!CleanupGuard.spellingFix(Array("ich".unicodeScalars), Array("ihc".unicodeScalars)))
        #expect(!CleanupGuard.spellingFix(Array("a1234".unicodeScalars), Array("a1235".unicodeScalars)))
        // Letters outside the BMP count as one letter each, as they do in the TypeScript test.
        #expect(CleanupGuard.spellingFix(Array("a\u{1D4B3}bc".unicodeScalars), Array("a\u{1D4B4}bc".unicodeScalars)))
    }

    // MARK: - v3: apostrophes, umlauts and the word list at "Nur Zeichensetzung"

    @Test func anApostropheInsideAWordAndUmlautsAreNotChangesOfAWord() {
        #expect(strict("Geht's, don\u{2019}t, O'Brien, l`amour, na\u{B4}ja, don\u{2BC}t") == ["gehts", "dont", "obrien", "lamour", "naja", "dont"])
        // Only between two letters: a quote, a lone apostrophe and the opening quote separate words as before.
        #expect(strict("'ja' 'nein' ja' it\u{2018}s") == ["ja", "nein", "ja", "it", "s"])
        #expect(strict("don''t") == ["don", "t"])
        #expect(strict("Übersehen Grüße schön Öl Äpfel Straße STRASSE GRO\u{1E9E}") == ["uebersehen", "gruesse", "schoen", "oel", "aepfel", "strasse", "strasse", "gross"])
        // The other presets keep the words as they are.
        #expect(CleanupGuard.words("geht's Grüße").map(text) == ["geht", "s", "grüße"])
    }

    @Test func nurZeichensetzungTakesGehtsForGehtsAndUebersehenForUebersehen() {
        #expect(accepts("Wie geht's dir heute?", "wie gehts dir heute", .punctuation))
        #expect(accepts("Wie geht\u{2019}s dir heute?", "wie gehts dir heute", .punctuation))
        #expect(accepts("Wie gehts dir heute?", "wie geht's dir heute", .punctuation))
        #expect(accepts("I don't think so.", "i dont think so", .punctuation))
        #expect(accepts("Ich habe nichts übersehen.", "ich habe nichts uebersehen", .punctuation))
        #expect(accepts("Ich habe nichts uebersehen.", "ich habe nichts übersehen", .punctuation))
        #expect(accepts("Wir freuen uns auf die Grüße.", "wir freuen uns auf die gruesse", .punctuation))
        #expect(accepts("Die Straße ist lang.", "die strasse ist lang", .punctuation))
        // A contraction of two words said is one word where two were said; the folded words may still differ by a spelling fix, but not be other words.
        #expect(!accepts("Wie geht's dir?", "wie geht es dir", .punctuation))
        #expect(accepts("Ich habe nichts übersehen.", "ich habe nichts ubersehen", .punctuation))
        #expect(!accepts("Ich habe nichts gesehen.", "ich habe nichts übersehen", .punctuation))
    }

    @Test func nurZeichensetzungTakesAWordOfTheWordListForAMisheardNameAndNothingElse() {
        let said = "hallo yannick wie gehts"
        let answer = "Hallo Jannik, wie geht's?"
        #expect(accepts(answer, said, .punctuation, vocabulary: ["Jannik"]))
        #expect(!accepts(answer, said, .punctuation, vocabulary: []))
        #expect(!accepts(answer, said, .punctuation, vocabulary: ["Daniel"]))
        // A name in the list written with an umlaut is compared as it is folded.
        #expect(accepts("Ich habe Herrn Müller getroffen.", "ich habe herrn miller getroffen", .punctuation, vocabulary: ["Müller"]))
        #expect(!accepts("Ich habe Herrn Müller getroffen.", "ich habe herrn miller getroffen", .punctuation))
        // The word list does not allow a word added, dropped or moved, nor a lost negation.
        #expect(!accepts("Hallo Jannik Daniel.", "hallo yannick", .punctuation, vocabulary: ["Jannik", "Daniel"]))
        #expect(!accepts("Hallo Jannik.", "hallo yannick wie gehts", .punctuation, vocabulary: ["Jannik"]))
        #expect(!accepts("Hallo Jannik.", "yannick hallo", .punctuation, vocabulary: ["Jannik"]))
        #expect(!accepts("Hallo Jannik.", "hallo yannick nicht", .punctuation, vocabulary: ["Jannik"]))
        // A number is not a name: the number rule runs first.
        #expect(!accepts("Ich zahle 9000 Euro.", "ich zahle 1000 euro", .punctuation, vocabulary: ["9000"]))
    }

    // MARK: - 2. Numbers

    @Test(arguments: CleanupLevel.presets)
    func noNumberAppearsOrChanges(level: CleanupLevel) {
        #expect(!accepts("Ich will 15 Euro für das Essen heute Abend, danke.", "ich will 5 euro für das essen heute abend danke", level))
        #expect(!accepts("Die Nummer ist 12345679 und gilt nur heute, danke.", "die nummer ist 12345678 und gilt nur heute danke", level))
        #expect(!accepts("Es kostet 9.000 Euro im Monat, danke.", "es kostet 1000 euro im monat danke", level))
        // Existing decimal punctuation stays; punctuation must not infer a time.
        #expect(accepts("Wir brauchen noch 3,5 Stunden für das Projekt.", "wir brauchen noch 3,5 stunden für das projekt", level))
        #expect(!accepts("Es ist 10:30 Uhr, danke.", "es ist 10 30 uhr danke", level))
    }

    @Test(arguments: [CleanupLevel.light, .smooth, .polished])
    func aNumericSelfCorrectionKeepsTheOriginal(level: CleanupLevel) {
        #expect(!accepts("Wir treffen uns heute um 4 im Büro.", "wir treffen uns heute um 3 nein um 4 im büro", level))
    }

    @Test func digitsInAnyScriptCount() {
        #expect(CleanupGuard.digitRuns("a1 b٢٣ 4,5") == Set(["1", "٢٣", "4", "5"].map { Array($0.unicodeScalars) }))
        #expect(!accepts("Ich habe ٢٣ Äpfel gekauft.", "ich habe 23 äpfel gekauft", .light))
    }

    // MARK: - v3: what counts as one number

    @Test func aThousandsSeparatorAndExactlyThreeDigitsMakeOneNumber() {
        for written in ["1.000", "1,000", "1'000", "1\u{2019}000", "1 000", "1\u{2009}000"] { #expect(numbers(written) == ["1000"], "\(written)") }
        #expect(numbers("1 000 000 und 2.500,50") == ["1000000", "2500", "50"])
        #expect(numbers("12.345.678") == ["12345678"])
        #expect(numbers("٢.٠٠٠") == ["٢٠٠٠"])
        // Not exactly three digits, or another separator: separate numbers.
        #expect(numbers("1.00") == ["1", "00"])
        #expect(numbers("1.0000") == ["1", "0000"])
        #expect(numbers("1-000") == ["1", "000"])
        #expect(numbers("1\u{A0}000") == ["1", "000"])
        #expect(numbers("3,5 und 10:30") == ["3", "5", "10", "30"])
        #expect(CleanupGuard.digitRuns("1.000 und 1000 und 1 000").map(text) == ["1000"])
    }

    @Test(arguments: [CleanupLevel.light, .smooth, .polished])
    func oneThousandIsOneThousandInEitherDirection(level: CleanupLevel) {
        #expect(accepts("Die Summe ist 1.000 Euro für die Rechnung, danke.", "die summe ist 1000 euro für die rechnung danke", level))
        #expect(!accepts("Die Summe ist 2500 Euro für die Rechnung, danke.", "die summe ist 2,500 euro für die rechnung danke", level))
        #expect(accepts("Es kostet 1.000.000 Euro im Monat, danke.", "es kostet 1 000 000 euro im monat danke", level))
        // Another number, or one group more, is still another number.
        #expect(!accepts("Die Summe ist 9.000 Euro für die Rechnung, danke.", "die summe ist 1000 euro für die rechnung danke", level))
        #expect(!accepts("Die Summe ist 1.000.000 Euro für die Rechnung, danke.", "die summe ist 1000 euro für die rechnung danke", level))
    }

    @Test func nurZeichensetzungStillCountsWordsSoOneThousandIsTwoWordsThere() {
        #expect(!accepts("Die Summe ist 1.000 Euro.", "die summe ist 1000 euro", .punctuation))
        #expect(accepts("Die Summe ist 1000 Euro.", "die summe ist 1000 euro", .punctuation))
    }

    // MARK: - v3: list markers

    @Test func theNumbersOfAListAreMarkersNotNumbers() {
        #expect(numbers("1. Milch\n2) Brot\n  3. Eier", markers: true) == [])
        #expect(numbers("1. Milch\n2) Brot", markers: false) == ["1", "2"])
        #expect(numbers("10) Milch", markers: true) == [])
        // Every kind of line break starts a line, and so does the start of the text; indented by spaces or a tab.
        #expect(numbers("Liste:\r\n1. Milch\u{2028}2. Brot\u{85}3. Eier\u{B}4. Tee\u{C}5. Kaffee\u{2029}\t6. Wasser", markers: true) == [])
        // Only at the start of a line, and only with "." or ")" right behind the digits.
        #expect(numbers("Milch 1. Brot", markers: true) == ["1"])
        // v4: a dash with digits right behind it is a sign, bullet or not (the answer is judged as a number with a sign).
        #expect(numbers("Milch\n- 1. Brot", markers: true) == ["-1"])
        #expect(numbers("1 Milch", markers: true) == ["1"])
        #expect(numbers("1: Milch", markers: true) == ["1"])
        #expect(numbers("1 . Milch", markers: true) == ["1"])
        #expect(numbers("1,5 Liter", markers: true) == ["1", "5"])
        // A grouped number is read as a number first: 1.000 is no marker.
        #expect(numbers("1.000 Euro", markers: true) == ["1000"])
        // The dictation has no markers: a number there is a number.
        #expect(numbers("1. Milch") == ["1"])
    }

    @Test func aNumberedListPassesWhereItWasAskedForAndNowhereElse() {
        let said = "wir brauchen äpfel birnen und bananen"
        #expect(accepts("Wir brauchen:\n\n1. Äpfel\n2. Birnen\n3. Bananen", said, .polished))
        #expect(accepts("Wir brauchen:\n\n1) Äpfel\n2) Birnen\n3) Bananen", said, .polished))
        #expect(accepts("Wir brauchen:\n  1. Äpfel\n  2. Birnen\n  3. Bananen", said, .polished))
        // "Nur Zeichensetzung" keeps every word, and a marker is one.
        #expect(!accepts("Wir brauchen:\n\n1. Äpfel\n2. Birnen\n3. Bananen", said, .punctuation))
        // The marker is left out, a number behind it or inside a line is not.
        #expect(!accepts("Wir brauchen:\n\n1. Äpfel\n2. 5 Birnen", "wir brauchen äpfel und birnen", .polished))
        #expect(!accepts("Wir sehen uns am Montag, 5. Mai.", "wir sehen uns am montag", .polished))
    }

    // MARK: - v3: number words count for their own value

    @Test func germanCardinalsHaveTheirValue() {
        let expected: [String: Int] = [
            "null": 0, "ein": 1, "eins": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7,
            "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15, "sechzehn": 16, "siebzehn": 17,
            "achtzehn": 18, "neunzehn": 19, "zwanzig": 20, "dreißig": 30, "vierzig": 40, "fünfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
            // Compounds written as one word.
            "einundzwanzig": 21, "zweiundzwanzig": 22, "sechsunddreißig": 36, "achtundvierzig": 48, "neunundneunzig": 99,
            "hundert": 100, "einhundert": 100, "hunderteins": 101, "einhundertzwanzig": 120, "dreihundertfünfzig": 350,
            "zweihundertdreiundzwanzig": 223, "neunhundertneunundneunzig": 999,
            "tausend": 1000, "eintausend": 1000, "tausendeins": 1001, "zweitausend": 2000, "zwölftausend": 12000, "zweitausendfünfhundert": 2500,
            "einundzwanzigtausend": 21000, "hundertzwanzigtausend": 120000, "hunderttausend": 100_000, "zweihunderttausenddreihundert": 200_300,
            "neunhundertneunundneunzigtausendneunhundertneunundneunzig": 999_999,
        ]
        for (word, number) in expected { #expect(value(word) == number, "\(word)") }
        // Folded as in "Nur Zeichensetzung": the same without the umlaut and the ß.
        for (word, number) in ["fuenf": 5, "zwoelf": 12, "dreissig": 30, "fuenfzig": 50, "fuenfzehn": 15, "sechsunddreissig": 36, "dreihundertfuenfzig": 350] {
            #expect(value(word) == number, "\(word)")
        }
    }

    @Test func germanOrdinalsHaveTheirValue() {
        let stems: [String: Int] = [
            "erst": 1, "zweit": 2, "dritt": 3, "viert": 4, "fünft": 5, "sechst": 6, "siebt": 7, "acht": 8, "neunt": 9, "zehnt": 10, "elft": 11, "zwölft": 12,
            "dreizehnt": 13, "vierzehnt": 14, "fünfzehnt": 15, "sechzehnt": 16, "siebzehnt": 17, "achtzehnt": 18, "neunzehnt": 19,
            "zwanzigst": 20, "dreißigst": 30, "vierzigst": 40, "fünfzigst": 50, "sechzigst": 60, "siebzigst": 70, "achtzigst": 80, "neunzigst": 90,
            "einundzwanzigst": 21, "neunundneunzigst": 99, "hundertst": 100, "hunderterst": 101, "dreihundertst": 300, "tausendst": 1000,
            "zweitausendst": 2000, "zweitausenddritt": 2003,
        ]
        for (stem, number) in stems {
            for ending in ["e", "en", "er", "es", "em"] { #expect(value(stem + ending) == number, "\(stem + ending)") }
            // The stem alone is no ordinal ("erst" is "only", "acht" is the cardinal 8), nor is another ending.
            #expect(value(stem) == (stem == "acht" ? 8 : nil), "\(stem)")
            #expect(value(stem + "el") == nil, "\(stem)el")
        }
    }

    @Test func englishNumbersHaveTheirValue() {
        let expected: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
            "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000,
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
            "thirteenth": 13, "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40, "ninetieth": 90, "hundredth": 100, "thousandth": 1000,
        ]
        for (word, number) in expected { #expect(value(word) == number, "\(word)") }
    }

    @Test func halfIsNoNumberAndNeitherIsAnythingThatOnlyLooksLikeOne() {
        // "halb" and "half" were number words in the first v3 and give no allowance now.
        for word in ["halb", "halbe", "halber", "half", "halves"] { #expect(value(word) == nil, "\(word)") }
        // The words that ended in zehn, zig or teen, or began like an ordinal, but are none.
        for word in ["witzig", "fleißig", "wenig", "einzig", "dutzend", "fourteens", "someone", "ones", "tent", "thirds", "forties", "seconds", "billion", "billions"] {
            #expect(value(word) == nil, "\(word)")
        }
        // Whole words only, and only these.
        for word in ["uns", "viertel", "dreiviertel", "einkaufen", "nullen", "hunderte", "tausende", "jahrhundert", "jahrtausend", "keine", "eines", "sechsmal", "einmal",
                     "zehner", "drei1", "ei", "milliarde", "milliarden", "nachte", "dachte", "erst", "zweit", "million", "millionen", "millions", ""] {
            #expect(value(word) == nil, "\(word)")
        }
        // Compounds that are not numbers.
        for word in ["einsundzwanzig", "einzwanzig", "zweiundzehn", "nullhundert", "hunderthundert", "tausendtausend", "zweihundertdreihundert",
                     "dreihundertundfünfzig", "tausendnull", "hundertzwei1"] {
            #expect(value(word) == nil, "\(word)")
        }
    }

    @Test func millionNeedsANumberWordInFront() {
        #expect(values("eine million euro") == [1, 1_000_000])
        #expect(values("zwei millionen euro") == [2, 2_000_000])
        #expect(values("dreihundert millionen") == [300, 300_000_000])
        #expect(values("one million") == [1, 1_000_000])
        #expect(values("two million") == [2, 2_000_000])
        // Alone, behind a digit ("1 million" is left unsupported), behind a word that is no number, behind an ordinal or too large a number.
        #expect(values("million euro") == [])
        #expect(values("1 million") == [])
        #expect(values("1,5 millionen") == [])
        #expect(values("viele millionen") == [])
        #expect(values("zweite million") == [2])
        #expect(values("tausend millionen") == [1000])
    }

    @Test func everyNumberWordOfADictationGivesOneValue() {
        #expect(values("um drei oder vier uhr") == [3, 4])
        #expect(values("ein kunde zahlt tausend euro") == [1, 1000])
        // Spaces split compounds: the parts are their own words.
        #expect(values("twenty one und ein hundert") == [20, 1, 1, 100])
        #expect(values("halb drei") == [3])
        #expect(values("am fünften märz um zwei") == [5, 2])
    }

    @Test(arguments: [CleanupLevel.light, .smooth, .polished])
    func aNumberSaidInWordsMayComeBackInDigits(level: CleanupLevel) {
        #expect(accepts("3 Exemplare, bitte.", "drei exemplare bitte", level))
        #expect(accepts("Ich zahle 1.000 Euro für das Auto.", "ich zahle tausend euro für das auto", level))
        #expect(accepts("Wir treffen uns um 15 Uhr.", "wir treffen uns um fünfzehn uhr", level))
        #expect(accepts("Am 5. März kommt er.", "am fünften märz kommt er", level))
        #expect(accepts("We need 20 copies by Friday.", "we need twenty copies by friday", level))
        #expect(accepts("The 3rd of May is a holiday for us.", "the third of may is a holiday for us", level))
        // Compounds, by their value.
        #expect(accepts("Das macht 350 Euro für uns alle.", "das macht dreihundertfünfzig euro für uns alle", level))
        #expect(accepts("Das macht 2.500 Euro für uns alle.", "das macht zweitausendfünfhundert euro für uns alle", level))
        #expect(accepts("Er wurde 21 Jahre alt gestern.", "er wurde einundzwanzig jahre alt gestern", level))
        #expect(accepts("Das macht 2.000.000 Euro für uns alle.", "das macht zwei millionen euro für uns alle", level))
        // Whatever zeros stand in front, and wherever the separators.
        #expect(accepts("Wir treffen uns um 07 Uhr im Büro.", "wir treffen uns um sieben uhr im büro", level))
        // A short dictation: the digits are no word to look for among the words said.
        #expect(accepts("1.000 Euro", "tausend euro", level))
        #expect(accepts("3 Exemplare", "drei exemplare", level))
        #expect(accepts("21", "einundzwanzig", level))
        #expect(accepts("Am 5. März", "am fünften märz", level))
        // No number word said: no number may appear.
        #expect(!accepts("Wir treffen uns um 15 Uhr im Büro.", "wir treffen uns im büro", level))
    }

    @Test(arguments: [CleanupLevel.light, .smooth, .polished])
    func aNumberWordCountsOnlyForItsOwnValue(level: CleanupLevel) {
        // The two answers the first v3 let through.
        #expect(!accepts("Wir treffen uns um 15 Uhr.", "wir treffen uns um drei", level))
        #expect(!accepts("Ein Kunde zahlt 9000 Euro.", "ein kunde zahlt 1000 euro", level))
        // "ein" is 1, so 1 is the only number it can come back as.
        #expect(accepts("1 Kunde zahlt 1000 Euro.", "ein kunde zahlt 1000 euro", level))
        #expect(!accepts("2 Kunden zahlen 1000 Euro.", "ein kunde zahlt 1000 euro", level))
        // Off by a little, off by a unit, off by a magnitude.
        #expect(!accepts("Wir treffen uns um 4 Uhr im Büro.", "wir treffen uns um drei uhr im büro", level))
        #expect(!accepts("Wir treffen uns um 13 Uhr im Büro.", "wir treffen uns um drei uhr im büro", level))
        #expect(!accepts("Wir treffen uns um 30 Uhr im Büro.", "wir treffen uns um drei uhr im büro", level))
        #expect(!accepts("Das macht 3.000 Euro für uns alle.", "das macht dreihundert euro für uns alle", level))
        #expect(!accepts("Das macht 351 Euro für uns alle.", "das macht dreihundertfünfzig euro für uns alle", level))
        #expect(!accepts("Er wurde 12 Jahre alt gestern.", "er wurde einundzwanzig jahre alt gestern", level))
        #expect(!accepts("Das macht 1.000.000 Euro für uns alle.", "das macht zwei millionen euro für uns alle", level))
        // An ordinal is its number: the fifth is 5.
        #expect(!accepts("Am 6. März kommt er.", "am fünften märz kommt er", level))
        #expect(!accepts("The 4th of May is a holiday for us.", "the third of may is a holiday for us", level))
        // A short dictation: the same.
        #expect(!accepts("9.000 Euro", "tausend euro", level))
        #expect(!accepts("4 Exemplare", "drei exemplare", level))
        #expect(!accepts("12", "einundzwanzig", level))
        #expect(!accepts("9", "acht", level))
        // "halb" and "half" give no allowance.
        #expect(!accepts("Es kostet 5 Euro, danke.", "es kostet halb euro danke", level))
        #expect(!accepts("It takes 5 hours for sure.", "it takes half hours for sure", level))
        // Digits of another script have no value to compare.
        #expect(!accepts("Wir treffen uns um \u{667} Uhr im Büro.", "wir treffen uns um sieben uhr im büro", level))
    }

    @Test func nurZeichensetzungKeepsTheWordsSoTheDigitsStayOut() {
        #expect(!accepts("Wir treffen uns um 15 Uhr.", "wir treffen uns um fünfzehn uhr", .punctuation))
        #expect(!accepts("3 Exemplare", "drei exemplare", .punctuation))
        #expect(!accepts("1.000 Euro", "tausend euro", .punctuation))
    }

    @Test func aShortDictationStillCannotGrowWordsOrListMarkersThroughTheNumbers() {
        // The digits of the answer are free, judged by the number rule; anything else is still a word that was not said.
        #expect(!accepts("1.000 Euro, danke.", "tausend euro", .light))
        #expect(!accepts("3 Exemplare für Max", "drei exemplare", .light))
        #expect(!accepts("3", "ja gerne", .light))
        #expect(!accepts("1. Milch\n2. Brot", "milch brot", .polished))
        // Said in digits and written with a separator: still the number said.
        #expect(accepts("1.000 Euro", "1000 euro", .light))
        #expect(!accepts("9.000 Euro", "1000 euro", .light))
    }

    @Test func eachNumberWordIsUsedOnce() {
        let said = "wir brauchen drei exemplare für die kunden"
        #expect(accepts("Wir brauchen 3 Exemplare für die Kunden.", said, .light))
        // Two new numbers, one number word.
        #expect(!accepts("Wir brauchen 3 Exemplare für 4 Kunden.", said, .light))
        // The same number twice is two places.
        #expect(!accepts("Wir brauchen 3 Exemplare für 3 Kunden.", said, .light))
        // Each number word is used once, in order, with its surrounding context.
        #expect(accepts("Um 3 oder 4 Uhr.", "um drei oder vier uhr", .polished))
        #expect(!accepts("Um 4 oder 3 Uhr.", "um drei oder vier uhr", .polished))
        #expect(!accepts("Um 3 oder 3 Uhr.", "um drei oder vier uhr", .polished))
        #expect(!accepts("Um 3 oder 5 Uhr.", "um drei oder vier uhr", .polished))
        #expect(!accepts("Um 3, 4 oder 5 Uhr.", "um drei oder vier uhr", .polished))
        #expect(accepts("Wir brauchen 2 Exemplare und 2 Kunden und mehr Zeit.", "wir brauchen zwei exemplare und zwei kunden und mehr zeit", .light))
        #expect(!accepts("Wir brauchen 2 Exemplare und 2 Kunden und mehr Zeit.", "wir brauchen zwei exemplare und drei kunden und mehr zeit", .light))
        // A number already said does not use one up: "5" was said, "sechs" becomes 6.
        #expect(accepts("Wir brauchen 5 Äpfel und 6 Birnen.", "wir brauchen 5 äpfel und sechs birnen", .light))
        // The number words of a list: its markers are no numbers, the 3 behind one is.
        #expect(accepts("Wir brauchen:\n1. 3 Äpfel", "wir brauchen drei äpfel", .polished))
        #expect(!accepts("Wir brauchen:\n1. 4 Äpfel", "wir brauchen drei äpfel", .polished))
    }

    @Test func theNumberRuleOnItsOwn() {
        func keeps(_ said: String, _ answer: String) -> Bool { CleanupGuard.keepsNumbers(said, answer) }
        #expect(keeps("drei exemplare", "3 Exemplare") && keeps("drei oder vier", "4 oder 3") && keeps("tausend", "1.000"))
        #expect(keeps("5 äpfel", "5 Äpfel") && keeps("äpfel", "1. Äpfel") && keeps("äpfel", "Äpfel"))
        #expect(!keeps("äpfel", "5 Äpfel") && !keeps("drei", "4") && !keeps("drei", "3 4") && !keeps("halb", "5"))
    }

    @Test func onlyTheThreeShareLevelsHaveLimits() {
        // "Nur Zeichensetzung" compares word by word and the own prompt is not judged: no shares for either.
        #expect(CleanupLevel.punctuation.guardLimits == nil)
        #expect(CleanupLevel.custom.guardLimits == nil)
        for level in [CleanupLevel.light, .smooth, .polished] { #expect(level.guardLimits != nil, "\(level)") }
        #expect(CleanupLevel.light.guardLimits?.said == 0.60 && CleanupLevel.polished.guardLimits?.growth == 1.8)
        // And the guard still judges both as before, with the limits gone.
        #expect(!accepts("Ja bitte.", "nein danke", .punctuation))
        #expect(accepts("Nein, danke.", "nein danke", .punctuation))
        #expect(!accepts("Ich komme morgen nicht.", "ich komme morgen", .punctuation))
        #expect(accepts("Ich komme morgen nicht.", "ich komme morgen", .custom))
        #expect(accepts("Can you tell me when the train leaves?", "wann fährt der zug", .custom))
        #expect(!accepts(" \n", "wann fährt der zug", .custom) && !accepts("", "wann fährt der zug", .punctuation))
    }

    // MARK: - 3. Negations

    private static let strongNegations = ["nicht", "kein", "keine", "keinen", "keinem", "keiner", "keines", "nie", "niemals", "nichts", "niemand", "nirgends",
                                          "weder", "not", "never", "nothing", "nobody", "nowhere", "neither", "nor", "cannot"]

    @Test(arguments: strongNegations)
    func everyStrongNegationCounts(word: String) {
        let said = "wir haben heute \(word) mehr zu sagen und gehen jetzt nach hause"
        let kept = "Wir haben heute \(word) mehr zu sagen und gehen jetzt nach Hause."
        let lost = "Wir haben heute mehr zu sagen und gehen jetzt nach Hause."
        for level in [CleanupLevel.punctuation, .light, .smooth, .polished] {
            #expect(accepts(kept, said, level), "\(level) keeps \(word)")
            #expect(!accepts(lost, said, level), "\(level) loses \(word)")
        }
        #expect(CleanupGuard.negationCount(said) == 1)
    }

    @Test func aWordThatContainsOneIsNoNegation() {
        // Whole words only: "nicht" inside "nichtraucher", "not" inside "notiz".
        #expect(CleanupGuard.negationCount("nichtraucher und notiz und knot und nicht") == 1)
        #expect(accepts("Wir haben die Notiz gelesen und gehen jetzt nach Hause.", "wir haben die notiz gelesen und gehen jetzt nach hause", .light))
    }

    @Test func nein_and_no_areHowPeopleCorrectThemselves() {
        #expect(CleanupGuard.negationCount("Montag, nein, Dienstag. No, Friday.") == 0)
        #expect(accepts("Wir treffen uns am Dienstag im Büro.", "wir treffen uns am montag nein am dienstag im büro", .light))
        #expect(accepts("We meet on Tuesday at the office.", "we meet on monday no on tuesday at the office", .light))
    }

    @Test func contractionsCountOnce() {
        for apostrophe in ["'", "\u{2019}", "\u{2BC}", "\u{2018}", "`", "\u{B4}"] {
            for stem in ["don", "won", "isn", "can", "shouldn", "didn", "ain"] {
                let word = "\(stem)\(apostrophe)t"
                #expect(CleanupGuard.negationCount("i \(word) think so") == 1, "\(word)")
                #expect(CleanupGuard.negationCount("I \(word.uppercased()) think so") == 1, "\(word)")
            }
        }
        #expect(CleanupGuard.negationCount("it's what you'd say, that's all, I'll go") == 0)
        #expect(CleanupGuard.negationCount("he's not here") == 1)
        // Dropped, or kept with the other apostrophe.
        #expect(!accepts("I want that and I know it.", "i don't want that and i know it", .light))
        #expect(accepts("I don\u{2019}t want that and I know it.", "i don't want that and i know it", .light))
        #expect(accepts("I don\u{2019}t want that and I know it.", "i don't want that and i know it", .punctuation))
        // "not" becoming "don't" is still one negation.
        #expect(accepts("Please don't send the invoice before we have checked it.", "please do not send the invoice before we checked it", .polished))
    }

    @Test func cannotStandsForCant() {
        // "can't" and "cannot" are one negation each.
        #expect(accepts("I cannot go to the office today, sorry.", "i can't go to the office today sorry", .light))
    }

    // MARK: - v3: the same number of negations, not only "not fewer"

    private static let apostropheLess = ["dont", "cant", "wont", "isnt", "arent", "wasnt", "werent", "doesnt", "didnt", "hasnt", "havent", "hadnt", "wouldnt", "couldnt", "shouldnt",
                                         "mustnt", "neednt", "aint"]

    @Test(arguments: CleanupLevel.presets)
    func aNegationAddedIsAsBadAsOneLost(level: CleanupLevel) {
        #expect(!accepts("Ich komme morgen nicht.", "ich komme morgen", level))
        #expect(!accepts("Ich komme morgen nicht zum Treffen im Büro vorbei.", "ich komme morgen zum treffen im büro vorbei", level))
        #expect(!accepts("Please do not send the invoice to the customer today.", "please send the invoice to the customer today", level))
        #expect(!accepts("Please don't send the invoice to the customer today.", "please send the invoice to the customer today", level))
        for word in Self.strongNegations {
            #expect(!accepts("Wir haben heute \(word) mehr zu sagen und gehen jetzt nach Hause.", "wir haben heute mehr zu sagen und gehen jetzt nach hause", level), "\(level) adds \(word)")
        }
    }

    @Test func theOwnPromptMayAddOne() {
        #expect(accepts("Ich komme morgen nicht.", "ich komme morgen", .custom))
    }

    @Test func oneNegationSaidTwiceIsTwoNegations() {
        let said = "ich habe nie gesagt dass ich das nicht will"
        #expect(CleanupGuard.negationCount(said) == 2)
        #expect(accepts("Ich habe nie gesagt, dass ich das nicht will.", said, .light))
        #expect(!accepts("Ich habe nie gesagt, dass ich das will.", said, .light))
        #expect(!accepts("Ich habe nie gesagt, dass ich das nicht nie will.", said, .light))
    }

    @Test(arguments: CleanupLevel.presets)
    func theContractionsWithoutAnApostropheAreNegationsToo(level: CleanupLevel) {
        for word in Self.apostropheLess {
            let apostrophe = String(word.dropLast(2)) + "n't"
            #expect(CleanupGuard.negationCount("i \(word) think so") == 1, "\(word)")
            #expect(CleanupGuard.negationCount("I \(word.uppercased()) think so") == 1, "\(word)")
            #expect(CleanupGuard.negationCount("i \(apostrophe) think so") == 1, "\(apostrophe)")
            let said = "i \(word) think we should go there today"
            // The model adds the apostrophe: still one negation.
            #expect(accepts("I \(apostrophe) think we should go there today.", said, level), "\(level) \(apostrophe)")
            #expect(accepts("I \(word) think we should go there today.", said, level), "\(level) \(word)")
            // And lost, or added to a sentence without one.
            #expect(!accepts("I think we should go there today.", said, level), "\(level) loses \(word)")
            #expect(!accepts("I \(apostrophe) think we should go there today.", "i think we should go there today", level), "\(level) adds \(apostrophe)")
            #expect(!accepts("I \(word) think we should go there today.", "i think we should go there today", level), "\(level) adds \(word)")
        }
        #expect(accepts("I don't think so.", "i dont think so", level))
    }

    @Test func wholeWordsOnlyDontInsideAnotherWordIsNoNegation() {
        #expect(CleanupGuard.negationCount("wonton and canto and wontons and dontcare") == 0)
    }

    // MARK: - 4. Short dictations

    @Test func aShortDictationKeepsItsWords() {
        #expect(!accepts("Ja bitte.", "nein danke", .light))
        #expect(!accepts("Um neun.", "um acht", .light))
        #expect(!accepts("Ja.", "nein", .light))
        #expect(accepts("Nein, danke.", "nein danke", .light))
        #expect(accepts("Ja.", "ja", .light))
        // The length rule is still there.
        #expect(!accepts("Ja, das ist eine gute Frage, danke.", "ja", .light))
        // A spelling fix or an ending is the same word; under four letters it is not.
        #expect(accepts("Danke schön.", "danke schon", .light))
        #expect(accepts("Projekts.", "projekt", .light))
        #expect(!accepts("Okay, danke.", "ok danke", .light))
        // "Nur Zeichensetzung" asks the same of a short dictation as of a long one.
        #expect(accepts("Ok, danke.", "ok danke", .punctuation))
        #expect(!accepts("Ja, das ist gut.", "ja", .punctuation))
    }

    @Test func fillersDoNotMakeALongDictationShort() {
        // Three words besides the fillers: the share rules, not the short rule, and the number and negation rules too.
        #expect(accepts("Ich komme morgen.", "ähm ich komme morgen", .light))
        // Three words and a filler: the share rules apply, so a made-up sentence is out.
        #expect(!accepts("Ich komme morgen und bringe Kuchen für alle mit.", "ähm ich komme morgen", .light))
    }

    // MARK: - v3: a short dictation keeps a word, and the word list counts

    @Test func aShortDictationKeepsAtLeastAWord() {
        #expect(!accepts("👍", "ja gerne", .light))
        #expect(!accepts(".", "ja gerne", .smooth))
        #expect(!accepts("...", "ja", .polished))
        #expect(!accepts(".", "ähm", .light))
        #expect(accepts("Ähm.", "ähm", .light))
        #expect(accepts("Ja, gerne.", "ja gerne", .light))
        // Nothing to keep where nothing was said, and nothing to be like either.
        #expect(accepts("...", "...", .light))
        #expect(!accepts("Hallo.", "...", .light))
        #expect(!accepts("Jannik.", "...", .light, vocabulary: ["Jannik"]))
    }

    @Test func aWordOfTheWordListCountsAsTheWordThatWasSaid() {
        #expect(accepts("Hallo Jannik.", "hallo yannick", .light, vocabulary: ["Jannik"]))
        #expect(accepts("Danke, Jannik.", "danke yannick", .polished, vocabulary: ["Jannik"]))
        #expect(!accepts("Hallo Jannik.", "hallo yannick", .light))
        #expect(!accepts("Hallo Jannik.", "hallo yannick", .light, vocabulary: ["Daniel"]))
        // Still no sentence of its own.
        #expect(!accepts("Hallo Jannik, schön dich zu sehen, wie geht es dir?", "hallo yannick", .light, vocabulary: ["Jannik"]))
    }

    // MARK: - v4 (Codex R4, 14.10.2026): a sign belongs to its number

    /// The pairs of the fourth audit: the guards let the sign of a saldo and of a temperature go.
    private static let signsChanged: [(said: String, answer: String, why: String)] = [
        ("der saldo beträgt -1000 euro", "Der Saldo beträgt 1000 Euro.", "-1000 became 1000"),
        ("der saldo beträgt 1000 euro", "Der Saldo beträgt -1000 Euro.", "1000 became -1000"),
        ("die temperatur beträgt -20 grad", "Die Temperatur beträgt 20 Grad.", "-20 became 20"),
        ("die temperatur beträgt minus 20 grad", "Die Temperatur beträgt 20 Grad.", "minus 20 became 20"),
        ("die temperatur beträgt minus zwanzig grad", "Die Temperatur beträgt 20 Grad.", "minus zwanzig became 20"),
        ("die temperatur beträgt zwanzig grad", "Die Temperatur beträgt -20 Grad.", "zwanzig became -20"),
        ("das konto steht bei plus 50 euro", "Das Konto steht bei 50 Euro.", "plus 50 became 50"),
        ("die nummer ist +49 170 1234567", "Die Nummer ist 49 170 1234567.", "+49 became 49"),
    ]

    @Test(arguments: CleanupLevel.presets)
    func aChangedSignIsRejectedAtEveryPreset(level: CleanupLevel) {
        for item in Self.signsChanged { #expect(!accepts(item.answer, item.said, level), "\(level) \(item.why)") }
    }

    @Test func theOwnPromptIsNotJudgedByTheSigns() {
        for item in Self.signsChanged { #expect(accepts(item.answer, item.said, .custom), "\(item.why)") }
    }

    @Test(arguments: CleanupLevel.presets)
    func theSameSignWrittenAnotherWayPasses(level: CleanupLevel) {
        #expect(accepts("Der Saldo beträgt -1000 Euro.", "der saldo beträgt -1000 euro", level))
        #expect(accepts("Der Saldo beträgt \u{2212}1000 Euro.", "der saldo beträgt -1000 euro", level), "the real minus")
        #expect(accepts("Der Saldo beträgt \u{2013}1000 Euro.", "der saldo beträgt -1000 euro", level), "the en dash")
        #expect(accepts("Der Saldo beträgt - 1000 Euro.", "der saldo beträgt -1000 euro", level), "one space")
        #expect(accepts("Die Temperatur beträgt minus 20 Grad.", "die temperatur beträgt minus 20 grad", level), "the words kept")
        #expect(accepts("Die Temperatur beträgt minus zwanzig Grad.", "die temperatur beträgt minus zwanzig grad", level), "the words kept")
        #expect(accepts("Die Nummer ist +49 170 1234567.", "die nummer ist +49 170 1234567", level), "the plus kept")
    }

    @Test(arguments: [CleanupLevel.light, .smooth, .polished])
    func theShareLevelsMayWriteTheWordsAsDigitsWithTheSameSign(level: CleanupLevel) {
        #expect(accepts("Der Saldo beträgt \u{2212}1.000 Euro.", "der saldo beträgt -1000 euro", level), "regrouped")
        #expect(accepts("Die Temperatur beträgt -20 Grad.", "die temperatur beträgt minus 20 grad", level), "minus 20")
        #expect(accepts("Die Temperatur beträgt -20 Grad.", "die temperatur beträgt minus zwanzig grad", level), "minus zwanzig")
        #expect(accepts("Das Konto steht bei +50 Euro.", "das konto steht bei plus 50 euro", level), "plus 50")
    }

    @Test func nurZeichensetzungKeepsTheWordsSoNeitherRegroupingNorMinusBecomesASign() {
        #expect(!accepts("Der Saldo beträgt \u{2212}1.000 Euro.", "der saldo beträgt -1000 euro", .punctuation))
        #expect(!accepts("Die Temperatur beträgt -20 Grad.", "die temperatur beträgt minus 20 grad", .punctuation))
    }

    @Test func aHyphenBehindALetterOrADigitIsARangeOrACodeNotASign() {
        #expect(numbers("Seite 3-5") == ["3", "5"])
        #expect(numbers("Modell A-1") == ["1"])
        #expect(numbers("2026-10-14") == ["2026", "10", "14"])
        #expect(numbers("x²-5") == ["5"])
        #expect(numbers("3 -5") == ["3", "-5"])
        #expect(numbers("3- 5") == ["3", "5"])
        for level in CleanupLevel.presets {
            #expect(accepts("Das steht auf Seite 3\u{2013}5.", "das steht auf seite 3-5", level), "\(level)")
            #expect(accepts("Das ist Modell A-1 mit 5 Teilen.", "das ist modell a-1 mit 5 teilen", level), "\(level)")
        }
        #expect(!accepts("Das ist Modell A-1 mit -5 Teilen.", "das ist modell a-1 mit 5 teilen", .light))
    }

    @Test func numbersCarryTheirSignAMinusARealMinusAnEnDashAPlusTheWordsMinusAndPlus() {
        #expect(numbers("-1000") == ["-1000"])
        #expect(numbers("\u{2212}1.000") == ["-1000"])
        #expect(numbers("\u{2013}5") == ["-5"])
        #expect(numbers("+49 30 123456") == ["+49", "30", "123456"])
        // A space and exactly three digits are a thousands group, with a sign or without.
        #expect(numbers("+49 170") == ["+49170"])
        #expect(numbers("- 5") == ["-5"])
        #expect(numbers("+\u{A0}5") == ["+5"])
        #expect(numbers("-\u{2009}5") == ["-5"])
        // Not two spaces, and not a sign that is not right in front.
        #expect(numbers("-  5") == ["5"])
        #expect(numbers("- a 5") == ["5"])
        #expect(numbers("minus 20") == ["-20"])
        #expect(numbers("Minus 20 und PLUS 3") == ["-20", "+3"])
        #expect(numbers("minus: 20") == ["-20"])
        #expect(numbers("minus 1.000") == ["-1000"])
        #expect(numbers("minus 3,5") == ["-3", "5"])
        #expect(numbers("-3,5") == ["-3", "5"])
        #expect(numbers("minus -5") == ["-5"])
        #expect(numbers("1000 minus 5") == ["1000", "-5"])
        #expect(numbers("minus20") == ["20"])
        #expect(numbers("Kaminus 20") == ["20"])
        #expect(numbers("minus ähm 20") == ["20"])
        #expect(numbers("-٢٣") == ["-٢٣"])
        #expect(numbers("-1. Milch", markers: true) == ["-1"])
        #expect(numbers("1. Milch\nminus 2 Brot", markers: true) == ["-2"])
        #expect(CleanupGuard.digitRuns("-5 und 5 und minus 5").map(text).sorted() == ["-5", "5"])
    }

    @Test func aNumberWordHasTheSignOfTheWordRightBeforeIt() {
        func entries(_ text: String) -> [String] {
            CleanupGuard.numberWords(CleanupGuard.words(text)).map { "\($0.sign)\($0.value)@\($0.position)" }
        }
        #expect(entries("minus zwanzig und plus drei und vier") == ["-20@1", "+3@4", "4@6"])
        #expect(entries("minus ähm zwanzig") == ["20@2"])
        #expect(entries("zwanzig minus drei") == ["20@0", "-3@2"])
        #expect(entries("minus zwei millionen") == ["-2@1", "-2000000@2"])
        #expect(entries("zwei millionen") == ["2@0", "2000000@1"])
        #expect(entries("minus million") == [])
        #expect(entries("minus twenty one") == ["-20@1", "1@2"])
        #expect(values("minus zwanzig und plus drei") == [20, 3])
    }

    @Test func theNumberRuleReadsTheSign() {
        func keeps(_ said: String, _ answer: String) -> Bool { CleanupGuard.keepsNumbers(said, answer) }
        #expect(keeps("-1000 euro", "\u{2212}1.000 Euro"))
        #expect(keeps("minus 20 grad", "-20 Grad"))
        #expect(keeps("minus zwanzig", "-20"))
        #expect(keeps("plus fünf", "+5"))
        #expect(keeps("minus zwei millionen", "-2.000.000"))
        #expect(keeps("minus 5", "minus 5"))
        #expect(keeps("-5", "- 5"))
        #expect(!keeps("-1000", "1000"))
        #expect(!keeps("1000", "-1000"))
        #expect(!keeps("minus 20 grad", "20 Grad"))
        #expect(!keeps("minus zwanzig", "20"))
        #expect(!keeps("zwanzig", "-20"))
        #expect(!keeps("plus 5", "5"))
        #expect(!keeps("5", "+5"))
        #expect(!keeps("minus 5", "+5"))
        #expect(!keeps("plus fünf", "5"))
        #expect(!keeps("minus zwei millionen", "2.000.000"))
        #expect(!keeps("zwei millionen", "-2.000.000"))
        #expect(!keeps("minus zwanzig", "-21"))
        // A sign is not a number word's value: each word is still used once.
        #expect(!keeps("minus drei", "-3 und -3"))
    }

    @Test func nurZeichensetzungKeepsTheSignOfEveryNumberInItsPlace() {
        #expect(CleanupGuard.keepsSigns("der saldo ist -5 und das limit ist 5", "Der Saldo ist -5 und das Limit ist 5."))
        #expect(!CleanupGuard.keepsSigns("der saldo ist -5 und das limit ist 5", "Der Saldo ist 5 und das Limit ist 5."))
        #expect(!CleanupGuard.keepsSigns("der saldo ist -5 und das limit ist 5", "Der Saldo ist 5 und das Limit ist -5."))
        #expect(CleanupGuard.keepsSigns("minus 5", "-5"))
        #expect(CleanupGuard.keepsSigns("5 minus 3", "5 - 3"))
        #expect(!CleanupGuard.keepsSigns("3 - 5", "3\u{2013}5"))
        // Another count of numbers is no sign lost: the words have judged a number regrouped or replaced by a word of the word list.
        #expect(CleanupGuard.keepsSigns("-5", "Danke."))
        #expect(CleanupGuard.keepsSigns("1.000", "1. 000"))
        #expect(CleanupGuard.keepsSigns("", "-5"))
        // The other presets judge the set of numbers: a number said twice, with and without its sign, can lose it.
        #expect(!accepts("Der Saldo ist 5 und das Limit ist 5.", "der saldo ist -5 und das limit ist 5", .punctuation))
        #expect(accepts("Der Saldo ist -5 und das Limit ist 5.", "der saldo ist -5 und das limit ist 5", .punctuation))
    }

    // MARK: - v4: a short dictation keeps every word

    /// The pairs of the fourth audit: a short reply lost its denial or all its words.
    private static let shortRepliesLost: [(said: String, answer: String, why: String)] = [
        ("nein danke", "Danke.", "nein dropped"),
        ("nein danke", "Nein.", "danke dropped"),
        ("nein danke", "!", "no word left"),
        ("nein danke", "👍", "no word left, an emoji"),
        ("ja danke", "👍", "no word left, an emoji"),
        ("ja", "...", "no word left"),
        ("ja gerne", "Gerne.", "ja dropped"),
    ]

    @Test(arguments: CleanupLevel.presets)
    func aShortReplyThatLostAWordIsRejectedAtEveryPreset(level: CleanupLevel) {
        for item in Self.shortRepliesLost { #expect(!accepts(item.answer, item.said, level), "\(level) \(item.why)") }
        #expect(!accepts("Danke.", "ähm nein danke", .light))
    }

    @Test(arguments: CleanupLevel.presets)
    func aShortReplyThatKeepsItsWordsPasses(level: CleanupLevel) {
        #expect(accepts("Nein, danke.", "nein danke", level))
        #expect(accepts("Ja.", "ja", level))
        #expect(accepts("Ja, gerne.", "ja gerne", level))
    }

    @Test func aFillerIsNoWordExceptAtNurZeichensetzung() {
        for level in [CleanupLevel.light, .smooth, .polished] { #expect(accepts("Ja.", "ähm ja", level), "\(level)") }
        #expect(!accepts("Ja.", "ähm ja", .punctuation))
        // Where the words are, their order is not read (the share levels never read it).
        #expect(accepts("Nein, ja.", "ja nein", .light))
        // The own prompt may do anything.
        #expect(accepts("Danke.", "nein danke", .custom))
    }

    @Test(arguments: CleanupLevel.presets)
    func okAndOkayAreTwoDifferentShortWords(level: CleanupLevel) {
        // Under four letters `similar` wants the same word: rejected at every preset, as before.
        #expect(!accepts("Okay.", "ok", level))
    }

    @Test func aWordThatIsGoneNeedsAVocabularyWordOfItsOwnThatWasNotSaid() {
        // The transcription misheard a name; the vocabulary's spelling stands for it.
        #expect(accepts("Hallo Jannik.", "hallo yannick", .light, vocabulary: ["Jannik"]))
        #expect(accepts("Danke, Jannik.", "danke yannick", .polished, vocabulary: ["Jannik"]))
        // One vocabulary word does not stand for two words that are gone.
        #expect(!accepts("Jannik.", "hallo yannick", .light, vocabulary: ["Jannik"]))
        #expect(!accepts("Jannik.", "nein yannick", .smooth, vocabulary: ["Jannik"]))
        // A name that was said stands for itself and nothing else.
        #expect(!accepts("Jannik.", "ja jannik", .light, vocabulary: ["Jannik"]))
        #expect(accepts("Ja, Jannik.", "ja jannik", .light, vocabulary: ["Jannik"]))
        // A name the transcription split in two: the part that is no longer `similar` is the one the vocabulary replaces.
        for level in [CleanupLevel.light, .smooth, .polished] { #expect(accepts("Kubernetes.", "kuber netes", level, vocabulary: ["Kubernetes"]), "\(level)") }
        #expect(!accepts("Kubernetes.", "kuber netes", .light))
        #expect(!accepts("Kubernetes.", "kuber netes", .punctuation, vocabulary: ["Kubernetes"]))
    }

    @Test func aNumberInAShortDictationComesBackAsItsDigitsOrStaysAWord() {
        #expect(!accepts("Euro.", "tausend euro", .light))
        #expect(accepts("Tausend Euro.", "tausend euro", .light))
        #expect(accepts("1.000 Euro", "tausend euro", .light))
        #expect(!accepts("Euro.", "1000 euro", .light))
        #expect(accepts("1000 Euro.", "1000 euro", .light))
        #expect(accepts("1.000 Euro", "1000 euro", .light))
        // "1.000" is "1" and "000" to the words, and one number to the digits.
        #expect(!accepts("1000", "1.000", .light))
        #expect(!accepts("Euro.", "1.000", .light))
        // Two numbers said, one left.
        #expect(!accepts("3, 4", "drei vier", .light))
        #expect(!accepts("3", "drei vier", .light))
        #expect(!accepts("Drei.", "drei vier", .light))
        // A million is its own number, and the "zwei" in front of it is part of it.
        #expect(accepts("2.000.000", "zwei millionen", .light))
        #expect(accepts("2 Millionen", "zwei millionen", .light))
        #expect(!accepts("Millionen.", "zwei millionen", .light))
        #expect(!accepts("2.000.001", "zwei millionen", .light))
    }

    @Test func minusZwanzigIsMinus20InAShortDictationTheSignAndTheNumberComeBackTogether() {
        #expect(accepts("-20", "minus zwanzig", .light))
        #expect(accepts("\u{2212}20", "minus zwanzig", .light))
        #expect(accepts("Minus zwanzig.", "minus zwanzig", .light))
        #expect(accepts("Minus 20.", "minus zwanzig", .light))
        #expect(!accepts("20", "minus zwanzig", .light))
        #expect(!accepts("+20", "minus zwanzig", .light))
        #expect(!accepts("Zwanzig.", "minus zwanzig", .light))
        #expect(!accepts("Minus.", "minus zwanzig", .light))
        #expect(accepts("+5", "plus fünf", .light))
        #expect(!accepts("5", "plus fünf", .light))
        #expect(!accepts("+5", "fünf", .light))
        #expect(accepts("-20 Grad", "-20 grad", .light))
        #expect(!accepts("20 Grad", "-20 grad", .light))
        #expect(!accepts("Grad.", "-20 grad", .light))
        #expect(accepts("-20", "minus 20", .light))
        #expect(!accepts("20", "minus 20", .light))
        #expect(!accepts("Minus.", "minus 20", .light))
    }
}
