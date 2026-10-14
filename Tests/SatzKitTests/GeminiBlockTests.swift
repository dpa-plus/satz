import Foundation
import Testing
@testable import SatzKit

// Gemini holds an answer back in more ways than SAFETY: PROHIBITED_CONTENT,
// BLOCKLIST, SPII (personal data) and RECITATION (a quote) end a candidate
// the same way, often with some text already written, and a prompt Gemini
// will not answer comes back with no candidate at all, the reason only in
// promptFeedback.blockReason. Windows and Linux read all of those as
// "Antwort verweigert" (desktop/test/geminiBlock.test.ts); the Mac read three
// of the finishReasons and any blockReason, null included.
//
// Everything here is made up and goes to a function or to a stub that
// answers from memory, never to a provider.

private let said = "ähm also der build ist äh gefailed weil the tests are flaky"
private let cleaned = "Also, der Build ist gefailed, weil the tests are flaky."
private let blocks = ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION"]

private func answer(_ finishReason: String?, text: String = cleaned) -> String {
    let reason = finishReason.map { #","finishReason":"\#($0)""# } ?? ""
    return #"{"candidates":[{"content":{"parts":[{"text":"\#(text)"}]}\#(reason)}],"usageMetadata":{"promptTokenCount":120,"candidatesTokenCount":30}}"#
}

private func parse(_ json: String, _ family: CleanupProvider.Family = .gemini) -> CleanupRequest.Answer? {
    CleanupRequest.parse(Data(json.utf8), family: family)
}

@Suite struct GeminiBlockParseTests {

    @Test(arguments: blocks)
    func aCandidateThatStoppedForABlockIsRefusedEvenWithAGoodLookingText(reason: String) {
        let parsed = parse(answer(reason))
        #expect(parsed?.refused == true, "\(reason)")
        #expect(parsed?.truncated == false, "\(reason)")
    }

    @Test func theOrdinaryEndsAreNotRefusedAndACutOffAnswerIsOnlyCutOff() {
        for reason in ["STOP", "MAX_TOKENS", "OTHER", "FINISH_REASON_UNSPECIFIED", nil] as [String?] {
            let parsed = parse(answer(reason))
            #expect(parsed?.refused == false, "\(reason ?? "none")")
            #expect(parsed?.text == cleaned, "\(reason ?? "none")")
        }
        let cut = parse(answer("MAX_TOKENS"))
        #expect(cut?.refused == false && cut?.truncated == true)
        // A word that only looks like one: the match is exact.
        #expect(parse(answer("safety"))?.refused == false)
        #expect(parse(answer("NOT_SAFETY"))?.refused == false)
    }

    @Test(arguments: ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "OTHER", "IMAGE_SAFETY"])
    func aPromptThatWasBlockedHasNoCandidateAndTheReasonInPromptFeedback(blockReason: String) {
        let parsed = parse(#"{"promptFeedback":{"blockReason":"\#(blockReason)"},"usageMetadata":{"promptTokenCount":120}}"#)
        #expect(parsed == CleanupRequest.Answer(text: "", refused: true, truncated: false, inputTokens: 120, outputTokens: nil, cost: nil), "\(blockReason)")
    }

    @Test func aBlockedPromptIsRefusedWhateverElseTheBodyHolds() {
        // A candidate with text, an empty list: the block decides, and no text is left to paste.
        let withCandidate = parse(#"{"promptFeedback":{"blockReason":"SAFETY"},"candidates":[{"content":{"parts":[{"text":"\#(cleaned)"}]},"finishReason":"STOP"}]}"#)
        #expect(withCandidate?.refused == true && withCandidate?.text == "")
        let emptyList = parse(#"{"promptFeedback":{"blockReason":"SAFETY","safetyRatings":[]},"candidates":[]}"#)
        #expect(emptyList?.refused == true && emptyList?.text == "")
    }

    @Test func aPromptFeedbackWithoutABlockChangesNothing() {
        let ratings = #"[{"category":"HARM_CATEGORY_HARASSMENT","probability":"NEGLIGIBLE"}]"#
        let body = #""candidates":[{"content":{"parts":[{"text":"\#(cleaned)"}]},"finishReason":"STOP"}]"#
        for feedback in [#"{"safetyRatings":\#(ratings)}"#, #"{"blockReason":null}"#, "{}", #""SAFETY""#, #"["SAFETY"]"#, "null"] {
            let parsed = parse(#"{"promptFeedback":\#(feedback),\#(body)}"#)
            #expect(parsed?.refused == false && parsed?.text == cleaned, "\(feedback)")
        }
    }

    @Test func theOtherFamiliesDoNotTakeGeminisWordsForABlock() {
        let foreign = #""promptFeedback":{"blockReason":"SAFETY"},"finishReason":"SAFETY""#
        #expect(parse(#"{"choices":[{"message":{"content":"\#(cleaned)"},\#(foreign)}],\#(foreign)}"#, .openAI)?.refused == false)
        #expect(parse(#"{"content":[{"type":"text","text":"\#(cleaned)"}],\#(foreign)}"#, .anthropic)?.refused == false)
    }
}

/// Answers every request with one body, for this file only.
private final class GeminiStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func client(replying body: String) -> CleanupClient {
        self.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStub.self]
        return CleanupClient(session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized) struct GeminiBlockClientTests {

    private func job() -> CleanupJob {
        CleanupJob(provider: .google, model: CleanupCatalog.model(CleanupProvider.google.defaultModel, for: .google),
                   key: "test-key-not-real", level: .light)
    }

    /// A text the guard would accept, so only the block can be what turns it down.
    @Test(arguments: [
        answer("SAFETY"), answer("BLOCKLIST"), answer("PROHIBITED_CONTENT"), answer("SPII"), answer("RECITATION"),
        #"{"promptFeedback":{"blockReason":"SAFETY"}}"#,
        #"{"promptFeedback":{"blockReason":"BLOCKLIST"},"usageMetadata":{"promptTokenCount":120}}"#,
    ])
    func everyBlockEndsAsAnswerRefusedAndTheOriginalIsPasted(body: String) async {
        let result = await GeminiStub.client(replying: body).run(job(), text: said)
        #expect(result.failure == .answerRefused, "\(body)")
        #expect(result.text == said && result.cleaned == nil, "\(body)")
        #expect(CleanupFailure.answerRefused.code == "answer-refused")
    }

    @Test func theSameTextWithANormalEndIsCleaned() async {
        let result = await GeminiStub.client(replying: answer("STOP")).run(job(), text: said)
        #expect(result.failure == nil && result.text == cleaned)
    }
}
