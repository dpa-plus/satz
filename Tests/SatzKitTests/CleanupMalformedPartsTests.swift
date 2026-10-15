import Foundation
import Testing
@testable import SatzKit

private let fullDictation = "bitte schreibe morgen eine kurze nachricht an max"
private let partialDictation = "Bitte schreibe morgen eine kurze Nachricht."

private func malformedBodies() throws -> [(CleanupProvider.Family, Data)] {
    let objects: [(CleanupProvider.Family, [String: Any])] = [
        (.openAI, ["choices": [["message": ["content": [["text": partialDictation], ["text": 17]]], "finish_reason": "stop"]]]),
        (.anthropic, ["content": [["type": "text", "text": partialDictation], ["type": "text", "text": 17]], "stop_reason": "end_turn"]),
        (.gemini, ["candidates": [["content": ["parts": [["text": partialDictation], ["text": 17]]], "finishReason": "STOP"]]]),
    ]
    return try objects.map { ($0.0, try JSONSerialization.data(withJSONObject: $0.1)) }
}

/// A malformed part must invalidate the whole answer; silently discarding it
/// can turn an unreadable response into a plausible shortened dictation.
@Suite(.serialized) struct CleanupMalformedPartsTests {
    @Test func malformedTextPartsDoNotBecomePartialAnswers() throws {
        for (family, body) in try malformedBodies() {
            #expect(CleanupRequest.parse(body, family: family) == nil, "\(family)")
        }
    }

    @Test func aMalformedPartRetainsTheCompleteOriginalAtEveryPreset() async throws {
        let body = try #require(try malformedBodies().first?.1)
        MalformedCleanupStub.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MalformedCleanupStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for level in CleanupLevel.presets {
            let job = CleanupJob(provider: .custom, model: CleanupCatalog.model("stand-in", for: .custom),
                                 address: "http://127.0.0.1:9/v1", key: nil, level: level)
            let result = await CleanupClient(session: session).run(job, text: fullDictation)
            #expect(result.text == fullDictation, "\(level)")
            #expect(result.failure == .providerError, "\(level)")
            #expect(result.cleaned == nil, "\(level)")
        }
    }

    @Test func validMultipartAnswersStillKeepAllTheirText() throws {
        let cases: [(CleanupProvider.Family, String)] = [
            (.openAI, #"{"choices":[{"message":{"content":["Hallo ",{"type":"text","text":"Welt."}]}}]}"#),
            (.anthropic, #"{"content":[{"type":"thinking","thinking":"ignored"},{"type":"text","text":"Hallo "},{"type":"text","text":"Welt."}],"stop_reason":"end_turn"}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"ignored"},{"text":"Hallo "},{"text":"Welt."}]},"finishReason":"STOP"}]}"#),
        ]
        for (family, json) in cases {
            #expect(CleanupRequest.parse(Data(json.utf8), family: family)?.text == "Hallo Welt.", "\(family)")
        }
    }
}

private final class MalformedCleanupStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = Data()
    static var body: Data {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
