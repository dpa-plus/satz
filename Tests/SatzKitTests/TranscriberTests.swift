import Foundation
import Testing
@testable import SatzKit

@Test func theRequestCarriesTheKeyModelAndAudio() throws {
    var settings = Transcriber.Settings()
    settings.model = "gpt-transcribe"
    let request = Transcriber(settings: settings)
        .makeRequest(wav: Data("RIFFxxxx".utf8), apiKey: "sk-test")

    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)

    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(body.contains("gpt-transcribe"))
    #expect(body.contains("filename=\"speech.wav\""))
    #expect(body.contains("RIFFxxxx"))
}

@Test func everyRequestIsBounded() {
    // A dictation tool that can hang is worse than one that fails: you cannot
    // tell hung from slow, so you sit there waiting.
    var settings = Transcriber.Settings()
    settings.timeout = 12
    let request = Transcriber(settings: settings).makeRequest(wav: Data(), apiKey: "sk")

    #expect(request.timeoutInterval == 12)
}

@Test func vocabularyIsSentOnlyWhenItHasContent() throws {
    var withWords = Transcriber.Settings()
    withWords.vocabulary = "ACON, Immofanten, Prozesshub"
    let filled = String(
        decoding: try #require(Transcriber(settings: withWords).makeRequest(wav: Data(), apiKey: "k").httpBody),
        as: UTF8.self
    )
    #expect(filled.contains("name=\"prompt\""))
    #expect(filled.contains("Immofanten"))

    let empty = String(
        decoding: try #require(Transcriber().makeRequest(wav: Data(), apiKey: "k").httpBody),
        as: UTF8.self
    )
    #expect(!empty.contains("name=\"prompt\""))
}

@Test func languageIsOmittedSoTheModelCanDetectIt() throws {
    // Omitted on purpose: a fixed language would mangle a sentence that
    // switches between German and English halfway through.
    let body = String(
        decoding: try #require(Transcriber().makeRequest(wav: Data(), apiKey: "k").httpBody),
        as: UTF8.self
    )
    #expect(!body.contains("name=\"language\""))
}

@Test func anEmptyKeyFailsBeforeAnythingIsUploaded() async {
    await #expect(throws: Transcriber.Failure.noKey) {
        try await Transcriber().transcribe(wav: Data("RIFF".utf8), apiKey: "")
    }
}

@Test func httpStatusesBecomeSomethingAUserCanActon() {
    #expect(Transcriber.failure(status: 401, body: Data()) == .unauthorized)
    #expect(Transcriber.failure(status: 403, body: Data()) == .unauthorized)
    #expect(Transcriber.failure(status: 429, body: Data()) == .rateLimited)
}

@Test func theServersOwnMessageIsKeptWhenThereIsOne() {
    let body = Data(#"{"error":{"message":"model_not_found"}}"#.utf8)

    #expect(Transcriber.failure(status: 404, body: body) == .server(status: 404, message: "model_not_found"))
    #expect(Transcriber.failure(status: 500, body: Data()) == .server(status: 500, message: nil))
}

@Test func networkErrorsAreNamedRatherThanNumbered() {
    #expect(Transcriber.translate(URLError(.timedOut)) == .timedOut)
    #expect(Transcriber.translate(URLError(.notConnectedToInternet)) == .offline)
    #expect(Transcriber.translate(URLError(.networkConnectionLost)) == .offline)
}

@Test func theTranscriptIsReadOutOfTheResponse() {
    #expect(Transcriber.text(in: Data(#"{"text":"Hallo Welt"}"#.utf8)) == "Hallo Welt")
    #expect(Transcriber.text(in: Data("not json".utf8)) == nil)
    #expect(Transcriber.text(in: Data(#"{"nope":1}"#.utf8)) == nil)
}
