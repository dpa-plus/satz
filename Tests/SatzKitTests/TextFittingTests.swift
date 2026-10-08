import Foundation
import Testing
@testable import SatzKit

private func insert(_ transcript: String, into text: String, after anchor: String) -> String {
    let source = text as NSString
    let location = source.range(of: anchor).location + (anchor as NSString).length
    let piece = TextFitting.fit(transcript, into: source, at: NSRange(location: location, length: 0))
    return source.replacingCharacters(in: NSRange(location: location, length: 0), with: piece)
}

@Test func aMidSentenceInsertLosesItsFullStopAndCapital() {
    // What MAI returned for "nur die PDF Dateien" on 03.10.2026.
    let text = "Schreib mir eine Funktion, die alle Rechnungen liest."
    #expect(insert("Nur die PDF-Dateien.", into: text, after: "Funktion")
            == "Schreib mir eine Funktion nur die PDF-Dateien, die alle Rechnungen liest.")
}

@Test func germanNounsKeepTheirCapital() {
    let text = "Bitte die Summe ausgeben."
    #expect(insert("Rechnungen ohne Datum.", into: text, after: "Summe")
            == "Bitte die Summe Rechnungen ohne Datum ausgeben.")
}

@Test func englishLowersTheFirstWordButNotAcronymsOrI() {
    #expect(TextFitting.lowerFirstWordIfSafe("Only the PDF files.") == "only the PDF files.")
    #expect(TextFitting.lowerFirstWordIfSafe("PDF files only.") == "PDF files only.")
    #expect(TextFitting.lowerFirstWordIfSafe("I think so.") == "I think so.")
}

@Test func aNewSentenceStaysASentence() {
    let text = "Das ist der erste Satz."
    #expect(insert("Und hier der zweite.", into: text, after: "Satz.") == "Das ist der erste Satz. Und hier der zweite.")
}

@Test func atTheStartNothingIsAdded() {
    #expect(TextFitting.fit("Hallo Welt.", into: "" as NSString, at: NSRange(location: 0, length: 0)) == "Hallo Welt.")
}

@Test func thePlaceholderAfterTheInsertIsSkipped() {
    // "…" is satz's placeholder; what counts is the text after it.
    let text = "Eine Funktion …, die liest."
    let location = ("Eine Funktion" as NSString).length
    let piece = TextFitting.fit("Nur PDFs.", into: text as NSString, at: NSRange(location: location, length: 0), skipping: 2)
    #expect(piece == " nur PDFs")
}

@Test func anEmojiCountsAsOneCharacter() {
    let text = "Ich mag 🍕"
    let piece = TextFitting.fit("Und Pasta.", into: text as NSString, at: NSRange(location: (text as NSString).length, length: 0))
    // A space before it (the emoji used to read as one), and "Und" lowered
    // because the emoji is not a sentence end.
    #expect(piece == " und Pasta.")
}

@Test func aLineBreakAtTheEdgeOfARecordingSurvives() {
    // "Neue Zeile, zweiter Punkt." said after a pause, after the replacements.
    let piece = Replacements.apply(Replacements.standard(for: .german), to: "Neue Zeile, zweiter Punkt.")
    #expect(insert(piece, into: "Erster Punkt.", after: "Erster Punkt.") == "Erster Punkt.\nZweiter Punkt.")
    let ending = Replacements.apply(Replacements.standard(for: .german), to: "Erster Punkt, neuer Absatz.")
    #expect(TextFitting.fit(ending, into: "" as NSString, at: NSRange(location: 0, length: 0)) == "Erster Punkt\n\n")
}

@Test func englishKeepsNamesAndIAsTheyAre() {
    #expect(TextFitting.lowerFirstWordIfSafe("Alice Johnson will join us.", context: "Tell the team that will join us.") == "Alice Johnson will join us.")
    #expect(TextFitting.lowerFirstWordIfSafe("Microsoft sent the invoice.", context: "We heard that sent the invoice today.") == "Microsoft sent the invoice.")
    #expect(TextFitting.lowerFirstWordIfSafe("I’m not sure.") == "I’m not sure.")
    #expect(TextFitting.lowerFirstWordIfSafe("I, for one, agree.") == "I, for one, agree.")
}

@Test func aMidSentenceInsertBeforeANounLosesItsFullStop() {
    #expect(insert("Alte.", into: "Ich habe gestern die Rechnung bezahlt.", after: "die") == "Ich habe gestern die Alte Rechnung bezahlt.")
}
