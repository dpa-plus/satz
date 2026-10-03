import Foundation
import Testing
@testable import SatzKit

private func insert(_ transcript: String, into text: String, after anchor: String, marker: Bool = false) -> String {
    let source = text as NSString
    let location = source.range(of: anchor).location + (anchor as NSString).length
    let piece = TextFitting.fit(transcript, into: source, at: NSRange(location: location, length: 0), markerFollows: marker)
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
    #expect(TextFitting.fit("Hallo Welt.", into: "" as NSString, at: NSRange(location: 0, length: 0), markerFollows: false) == "Hallo Welt.")
}

@Test func thePlaceholderAfterTheInsertIsSkipped() {
    // "…" is satz's placeholder; what counts is the text after it.
    let text = "Eine Funktion…, die liest."
    let location = ("Eine Funktion" as NSString).length
    let piece = TextFitting.fit("Nur PDFs.", into: text as NSString, at: NSRange(location: location, length: 0), markerFollows: true)
    #expect(piece == " nur PDFs")
}
