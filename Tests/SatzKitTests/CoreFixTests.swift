import Foundation
import Testing
@testable import SatzKit

// Tests for the review findings in the Mac core, and for the behaviour a
// mutation run showed nothing pinned (a reverted guard, a changed spacing
// rule and the like passed all 155 tests).

// MARK: - Transcriber

/// Answers from a script, for this file only: the other test files keep their
/// own scripts, and two suites sharing one would race.
private final class CoreStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var urls: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.urls.append(request.url!)
        let next = Self.script.isEmpty ? (status: 500, body: "") : Self.script.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func transcriber(_ script: [(Int, String)], settings: Transcriber.Settings = Transcriber.Settings()) -> Transcriber {
        self.script = script.map { (status: $0.0, body: $0.1) }
        urls = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreStub.self]
        return Transcriber(settings: settings, session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized)
struct CoreTranscriberTests {

    private let wav = Data("RIFF".utf8)

    @Test func aCustomEndpointWithoutAnAddressNeverGoesToOpenAI() {
        // The key and the recording went to api.openai.com when the address was cleared.
        let settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: nil)
        #expect(settings.baseURL.host == "address-missing.invalid")
        let request = Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "sk-custom")
        #expect(request.url?.host == "address-missing.invalid")
        #expect(request.url?.host != "api.openai.com")
    }

    @Test func aCustomAddressIsUsedAndTheBuiltInOnesIgnoreIt() {
        let mine = URL(string: "http://localhost:8080/v1")!
        #expect(Transcriber.Settings(provider: .custom, model: "m", customBaseURL: mine).baseURL == mine)
        #expect(Transcriber.Settings(provider: .groq, model: "", customBaseURL: mine).baseURL == Provider.groq.baseURL)
    }

    @Test func anEmptyModelTakesTheProvidersDefaultAndACustomEndpointHasNone() {
        #expect(Transcriber.Settings(provider: .groq, model: "  ").model == "whisper-large-v3-turbo")
        #expect(Transcriber.Settings(provider: .groq, model: " x ").model == "x")
        // Nothing to fall back to: Session refuses to record before this.
        #expect(Transcriber.Settings(provider: .custom, model: "  ").model == "")
    }

    @Test func anEmptyAccountIsNoCreditAndNotAProviderThatIsBusy() async {
        // OpenRouter answers 402; OpenAI answers 429 with insufficient_quota.
        let outOfCredit = CoreStub.transcriber([(402, ""), (200, #"{"text":"nein"}"#)])
        await #expect(throws: Transcriber.Failure.noCredit) { try await outOfCredit.transcribe(wav: wav, apiKey: "k") }
        #expect(CoreStub.urls.count == 1)

        let quota = CoreStub.transcriber([(429, #"{"error":{"code":"insufficient_quota"}}"#), (200, #"{"text":"nein"}"#)])
        await #expect(throws: Transcriber.Failure.noCredit) { try await quota.transcribe(wav: wav, apiKey: "k") }
        // Not tried again: topping up is the only way out.
        #expect(CoreStub.urls.count == 1)
    }

    @Test func aTooLargeUploadIsNamedAndNotWorthAskingAgain() async {
        #expect(Transcriber.failure(status: 413, body: Data()) == .tooLarge)
        let transcriber = CoreStub.transcriber([(413, #"{"error":{"message":"File too large"}}"#)])
        await #expect(throws: Transcriber.Failure.tooLarge) { try await transcriber.transcribe(wav: wav, apiKey: "k") }

        #expect(!Transcriber.Failure.tooLarge.retryHelps)
        for failure: Transcriber.Failure in [.noKey, .unauthorized, .rateLimited, .offline, .timedOut, .server(status: 500, message: nil),
                                             .unreadableResponse, .noCredit] {
            #expect(failure.retryHelps)
        }
    }

    @Test func theTooLargeMessageDoesNotSendTheUserToTextThatIsNotThere() {
        // One recording has no text on the card to copy; the audio is what is kept.
        let message = Transcriber.Failure.tooLarge.message
        #expect(!message.contains("kopieren"))
        #expect(!message.contains("Copy"))
    }

    @Test func theAnswerIsTrimmed() async throws {
        // A line break kept at the edge is pasted: fit() leaves newlines alone.
        let transcriber = CoreStub.transcriber([(200, #"{"text":"  Hallo Welt.\n"}"#)])
        #expect(try await transcriber.transcribe(wav: wav, apiKey: "k") == "Hallo Welt.")
    }

    @Test func theSecondCopyWaitsForTheUploadToo() {
        // 125,000 bytes are one megabit: a second more on a 1 Mbit/s line.
        #expect(Transcriber.backupDelay(after: 2.5, for: Data(count: 44)) == 2.5)
        #expect(Transcriber.backupDelay(after: 2.5, for: Data(count: 44 + 125_000)) == 3.5)
        #expect(Transcriber.backupDelay(after: 2.5, for: Data()) == 2.5)
        // Ten seconds of 16 kHz audio: the 2.6 s the comment on backupAfter names.
        let tenSeconds = Transcriber.backupDelay(after: 0, for: Data(count: 44 + 320_000))
        #expect(abs(tenSeconds - 2.56) < 0.0001)
    }

    @Test func noLanguageIsSentSoTheModelCanDetectIt() throws {
        for provider in [Provider.openAI, .openRouter] {
            let request = Transcriber(settings: Transcriber.Settings(provider: provider)).makeRequest(wav: wav, apiKey: "k")
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(!body.contains("language"))
        }
    }

    @Test func theMultipartFieldsAreTheModelAndJSON() throws {
        let settings = Transcriber.Settings(provider: .groq)
        let body = String(decoding: try #require(Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k").httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model\""))
        #expect(body.contains("whisper-large-v3-turbo"))
        #expect(body.contains("name=\"response_format\""))
    }
}

// MARK: - Replacements

private let german = Replacements.standard(for: .german)
private let english = Replacements.standard(for: .english)

@Test func aMarkTheModelWroteBesideASpokenMarkDoesNotDouble() {
    // "Hast du morgen Zeit. Fragezeichen." was ".?" and "Zeit? Fragezeichen." "??".
    #expect(Replacements.apply(german, to: "Hast du morgen Zeit. Fragezeichen.") == "Hast du morgen Zeit?")
    #expect(Replacements.apply(german, to: "Hast du morgen Zeit? Fragezeichen.") == "Hast du morgen Zeit?")
    #expect(Replacements.apply(german, to: "Das ist toll. Ausrufezeichen.") == "Das ist toll!")
    #expect(Replacements.apply(german, to: "Hallo Peter. Doppelpunkt. Ich schreibe dir.") == "Hallo Peter: Ich schreibe dir.")
    #expect(Replacements.apply(english, to: "Are you free tomorrow. Question mark.") == "Are you free tomorrow?")
}

@Test func aMarkTheModelWroteAfterASpokenMarkDoesNotDoubleEither() {
    // "Wie geht es dir Fragezeichen?" was "dir? ?".
    #expect(Replacements.apply(german, to: "Wie geht es dir Fragezeichen?") == "Wie geht es dir?")
    #expect(Replacements.apply(german, to: "Wie geht es dir, Fragezeichen?! Gut.") == "Wie geht es dir? Gut.")
    #expect(Replacements.apply(german, to: "Das ist toll Ausrufezeichen!") == "Das ist toll!")
}

@Test func twoSpokenMarksInARowKeepBoth() {
    // "?!" said as two words; only what the model wrote beside them goes.
    #expect(Replacements.apply(german, to: "Wirklich Fragezeichen Ausrufezeichen") == "Wirklich?!")
    #expect(Replacements.apply(german, to: "Wirklich Fragezeichen? Ausrufezeichen.") == "Wirklich?!")
    #expect(Replacements.apply(german, to: "Nein Ausrufezeichen Ausrufezeichen") == "Nein!!")
}

@Test func theSentenceAfterASpokenMarkStillStartsWithACapital() {
    #expect(Replacements.apply(german, to: "Hast du Zeit. Fragezeichen. wir treffen uns.") == "Hast du Zeit? Wir treffen uns.")
}

@Test func theLongestPhraseWinsWhereTwoOverlap() {
    let rules = [Replacement(spoken: "Zeile", written: "Z"), Replacement(spoken: "neue Zeile", written: "\n")]
    #expect(Replacements.apply(rules, to: "Erste neue Zeile Zweite") == "Erste\nZweite")
}

@Test func aLetterCodeOfFourLettersMatchesHoweverItIsSpelled() {
    let rules = [Replacement(spoken: "ABCD", written: "#")]
    #expect(Replacements.apply(rules, to: "mein a b c d code") == "mein # code")
    #expect(Replacements.apply(rules, to: "mein A. B. C. D. code") == "mein # code")
    // Five letters is a word, not a code.
    let five = [Replacement(spoken: "ABCDE", written: "#")]
    #expect(Replacements.apply(five, to: "mein a b c d e code") == "mein a b c d e code")
}

@Test func aCapitalComesAfterOpeningQuotesToo() {
    // The model wrote a quote after the line break, and the quoted word starts the sentence.
    #expect(Replacements.apply(german, to: "Erste Zeile. Neue Zeile. \"zweite Zeile\"") == "Erste Zeile.\n\"Zweite Zeile\"")
    #expect(Replacements.apply(german, to: "Erste Zeile. Neue Zeile. „zweite Zeile“") == "Erste Zeile.\n„Zweite Zeile“")
}

// MARK: - TextFitting

private func fit(_ transcript: String, into text: String, after anchor: String? = nil) -> String {
    let source = text as NSString
    let location = anchor.map { source.range(of: $0).location + ($0 as NSString).length } ?? 0
    return TextFitting.fit(transcript, into: source, at: NSRange(location: location, length: 0))
}

@Test func theFormalSieAndIhrKeepTheirCapital() {
    // "Vielen Dank für Ihr Anliegen": the word alone cannot say it is formal.
    #expect(fit("Sie haben recht.", into: "Vielen Dank, dass", after: "dass") == " Sie haben recht.")
    #expect(fit("Ihr Anliegen ist angekommen.", into: "Vielen Dank für", after: "für") == " Ihr Anliegen ist angekommen.")
    #expect(TextFitting.lowerFirstWordIfSafe("Sie haben recht.", context: "Vielen Dank, dass") == "Sie haben recht.")
    // Words that are small in every register still are.
    #expect(fit("Wir haben recht.", into: "Vielen Dank, dass", after: "dass") == " wir haben recht.")
    #expect(fit("Ich habe recht.", into: "Vielen Dank, dass", after: "dass") == " ich habe recht.")
}

@Test func anEllipsisTheModelWroteIsKeptWhereASentenceGoesOn() {
    // One full stop goes, because the sentence goes on; two are an ellipsis.
    #expect(fit("Hmm..", into: "ich glaube dass es geht", after: "glaube") == " Hmm..")
    #expect(fit("Hmm.", into: "ich glaube dass es geht", after: "glaube") == " Hmm")
}

@Test func nothingIsAddedRightAfterAnOpeningBracketOrQuote() {
    #expect(fit("Name", into: "Funktion (", after: "(") == "Name")
    #expect(fit("wir liefern", into: "Er sagte \"", after: "\"") == "wir liefern")
    #expect(fit("wir liefern", into: "Er sagte „", after: "„") == "wir liefern")
    #expect(fit("Name", into: "Funktion [", after: "[") == "Name")
    // After a word there is a space.
    #expect(fit("Name", into: "Funktion", after: "Funktion") == " Name")
}

@Test func aSpaceFollowsWhenANumberComesNext() {
    #expect(TextFitting.fit("Version", into: "5 ist da" as NSString, at: NSRange(location: 0, length: 0)) == "Version ")
    #expect(TextFitting.fit("Version", into: "Zwei ist da" as NSString, at: NSRange(location: 0, length: 0)) == "Version ")
    #expect(TextFitting.fit("Version", into: "" as NSString, at: NSRange(location: 0, length: 0)) == "Version")
    #expect(TextFitting.fit("Version", into: "(5)" as NSString, at: NSRange(location: 0, length: 0)) == "Version")
}

@Test func aColonEndsASentenceSoTheNextOneKeepsItsCapital() {
    #expect(fit("Das geht.", into: "Merke:", after: "Merke:") == " Das geht.")
    // A comma does not.
    #expect(fit("Das geht.", into: "Merke,", after: "Merke,") == " das geht.")
}

@Test func anEllipsisCharacterSaidOnItsOwnSitsRightAgainstTheWord() {
    #expect(fit("…", into: "Er wartet", after: "wartet") == "…")
    #expect(fit("Und weiter", into: "Er wartet…", after: "…") == " Und weiter")
}

@Test func aRecordingThatStartsALineIsNotMidSentence() {
    // A line break said first ("neue Zeile") starts a sentence: its full stop stays
    // even where a capitalised noun follows.
    #expect(TextFitting.fit("\nZweiter Punkt.", into: "Erster Punkt Rechnung" as NSString, at: NSRange(location: 12, length: 0))
            == "\nZweiter Punkt.")
}

@Test func aRecordingThatEndsALineGetsNoSpaceAfterIt() {
    #expect(TextFitting.fit("Erster Punkt\n", into: "Zweiter" as NSString, at: NSRange(location: 0, length: 0)) == "Erster Punkt\n")
    #expect(TextFitting.fit("Erster Punkt", into: "Zweiter" as NSString, at: NSRange(location: 0, length: 0)) == "Erster Punkt ")
}

@Test func anAcronymThatIsAlsoAWordIsNotLowered() {
    let context = "We think that citizens may apply for the visa"
    #expect(TextFitting.lowerFirstWordIfSafe("US citizens may apply.", context: context) == "US citizens may apply.")
    #expect(TextFitting.lowerFirstWordIfSafe("It may apply.", context: context) == "it may apply.")
    // A one letter word is no acronym.
    #expect(TextFitting.lowerFirstWordIfSafe("A visa may apply.", context: context) == "a visa may apply.")
}

// MARK: - Audio

@Test func aQuietButAudibleBlockStillDrawsABar() {
    // About -40 dB, above the -55 dB floor: the waveform must show it.
    let block: [Float] = [0.01, -0.01, 0.01, -0.01]
    let level = block.withUnsafeBufferPointer { AudioRecorder.level(of: $0, noiseFloor: -55) }
    #expect(level > 0.2 && level < 0.3)
    // The floor is the caller's: the same block is silence against -30 dB.
    #expect(block.withUnsafeBufferPointer { AudioRecorder.level(of: $0, noiseFloor: -30) } == 0)
}

private func le16(_ data: Data, at offset: Int) -> Int16 {
    Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
}

@Test func samplesAreScaledByThirtyTwoThousandSevenHundredSixtySevenAndTruncated() {
    let data = WAVEncoder.encode(samples: [0.5, -0.5, 0.25, 1, -1], sampleRate: 16_000)
    #expect(le16(data, at: 44) == 16383)
    #expect(le16(data, at: 46) == -16383)
    #expect(le16(data, at: 48) == 8191)
    // Both peaks are the same distance from zero; Int16.min is never written.
    #expect(le16(data, at: 50) == 32767)
    #expect(le16(data, at: 52) == -32767)
}

@Test func theBytesOfASampleAreLittleEndian() {
    // 0x1234 first as 0x34, 0x12: a big-endian file plays as loud noise.
    let value = Float(0x1234) / 32767
    let data = WAVEncoder.encode(samples: [value], sampleRate: 16_000)
    #expect(data[44] == 0x34)
    #expect(data[45] == 0x12)
}

@Test func theSampleRateAndLengthAreWhatWasAskedFor() {
    let data = WAVEncoder.encode(samples: Array(repeating: 0, count: 3), sampleRate: 44_100)
    #expect(data.count == 44 + 6)
    #expect(Int(data[24]) | Int(data[25]) << 8 | Int(data[26]) << 16 == 44_100)
    #expect(Int(data[28]) | Int(data[29]) << 8 | Int(data[30]) << 16 == 88_200)
}
