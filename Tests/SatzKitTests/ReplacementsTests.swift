import Testing
@testable import SatzKit

private let standard = Replacements.standard(for: .german)
private let english = Replacements.standard(for: .english)

// The inputs below are what MAI-Transcribe and GPT Transcribe actually sent
// back for spoken punctuation on 03.10.2026.

@Test func germanBracketsLoseTheModelsCommas() {
    let mai = "Schreib mir eine Funktion, Klammer auf Name, Klammer zu. Er hat gesagt, das geht."
    #expect(Replacements.apply(standard, to: mai) == "Schreib mir eine Funktion (Name). Er hat gesagt, das geht.")
}

@Test func quotesOpenAndCloseInTurn() {
    let mai = "Er hat gesagt, Zitat Anfang, wir liefern am Freitag, Zitat Ende. Punkt."
    #expect(Replacements.apply(standard, to: mai) == "Er hat gesagt \"wir liefern am Freitag\". Punkt.")
}

@Test func punctuationWordsBecomeMarks() {
    let mai = "Und noch was, Doppelpunkt, der Test ist rot, Ausrufezeichen."
    #expect(Replacements.apply(standard, to: mai) == "Und noch was: der Test ist rot!")
}

@Test func lineBreaksSwallowTheFullStopAfterThem() {
    let mai = "Erste Zeile. Neue Zeile. Zweite Zeile. Neuer Absatz. Dritte."
    #expect(Replacements.apply(standard, to: mai) == "Erste Zeile.\nZweite Zeile.\n\nDritte.")
}

@Test func englishWorksTheSameWay() {
    let gpt = "Write a function open bracket name close bracket. New line. Done"
    #expect(Replacements.apply(english, to: gpt) == "Write a function (name).\nDone")
}

@Test func letterCodesMatchHoweverTheModelSpellsThem() {
    let rules = [Replacement(spoken: "XX", written: "("), Replacement(spoken: "YY", written: ")")]
    #expect(Replacements.apply(rules, to: "Funktion XX Name YY und dann") == "Funktion (Name) und dann")
    #expect(Replacements.apply(rules, to: "Funktion x x Name y y und dann") == "Funktion (Name) und dann")
    #expect(Replacements.apply(rules, to: "Funktion X. X. Name Y. Y. und dann") == "Funktion (Name) und dann")
}

@Test func onlyWholeWordsTrigger() {
    // "Doppelpunkte" is a word of its own, and "XX" inside "XXL" is not a code.
    #expect(Replacements.apply(standard, to: "Zwei Doppelpunkte hintereinander") == "Zwei Doppelpunkte hintereinander")
    let rules = [Replacement(spoken: "XX", written: "(")]
    #expect(Replacements.apply(rules, to: "Größe XXL bitte") == "Größe XXL bitte")
}

@Test func rulesThatAreOffDoNothing() {
    #expect(Replacements.apply(standard, to: "Der Punkt ist, das geht nicht.") == "Der Punkt ist, das geht nicht.")
}

@Test func plainReplacementsAreInsertedAsTheyAre() {
    let rules = [Replacement(spoken: "meine Mail", written: "name@example.com")]
    #expect(Replacements.apply(rules, to: "Schick es an meine Mail, danke.") == "Schick es an name@example.com, danke.")
}

@Test func caseDoesNotMatter() {
    #expect(Replacements.apply(standard, to: "KLAMMER AUF test klammer zu") == "(test)")
}

@Test func noRulesLeavesTheTextAlone() {
    let text = "Klammer auf, nichts passiert."
    #expect(Replacements.apply([], to: text) == text)
}

@Test func theWordListGetsEveryTriggerThatIsOn() {
    let rules = [
        Replacement(spoken: "XX", written: "("),
        Replacement(spoken: "Punkt", written: ".", isOn: false),
        Replacement(spoken: " ", written: "?"),
    ]
    #expect(Replacements.phrases(rules) == ["XX"])
}

@Test func aTriggerStartingWithPunctuationDoesNotCrash() {
    // The tidying after "Doppelpunkt" skips ": ", which is where this rule matches.
    let rules = standard + [Replacement(spoken: ": Strich", written: "-")]
    #expect(!Replacements.apply(rules, to: "Doppelpunkt : Strich weiter").isEmpty)
}

@Test func eachLanguageHasItsOwnPredefinedRules() {
    // An English app does not want "Klammer auf", a German one not "open bracket".
    #expect(standard.contains { $0.spoken == "Klammer auf" })
    #expect(!standard.contains { $0.spoken == "open bracket" })
    #expect(english.contains { $0.spoken == "open bracket" })
    #expect(!english.contains { $0.spoken == "Klammer auf" })
    #expect(Replacements.apply(english, to: "He said, open quote, not today, close quote.") == "He said \"not today\".")
}

@Test func freshCopiesOfThePredefinedRulesCountAsTheSame() {
    #expect(Replacements.sameRules(Replacements.standard(for: .german), Replacements.standard(for: .german)))
    #expect(!Replacements.sameRules(standard, english))
}

@Test func germanLowAndHighQuotesPairUp() {
    let rules = [
        Replacement(spoken: "Zitat Anfang", written: "„"),
        Replacement(spoken: "Zitat Ende", written: "“"),
    ]
    let mai = "Er hat gesagt, Zitat Anfang, wir liefern am Freitag, Zitat Ende."
    #expect(Replacements.apply(rules, to: mai) == "Er hat gesagt „wir liefern am Freitag“.")
}

@Test func aNewLineStartsWithACapital() {
    let mai = "Erste Zeile, neue Zeile, zweite Zeile, Fragezeichen, und dann?"
    #expect(Replacements.apply(standard, to: mai) == "Erste Zeile\nZweite Zeile? Und dann?")
}
