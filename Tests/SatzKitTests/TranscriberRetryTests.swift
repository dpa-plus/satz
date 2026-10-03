import Foundation
import Testing
@testable import SatzKit

/// Answers requests from a script instead of the network.
final class ScriptedResponses: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [(status: Int, headers: [String: String], body: String)] = []
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let next = Self.script.isEmpty ? (status: 500, headers: [:], body: "") : Self.script.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(_ script: [(Int, [String: String], String)]) -> URLSession {
        self.script = script.map { (status: $0.0, headers: $0.1, body: $0.2) }
        requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedResponses.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized)
struct RetryTests {
    @Test func aThrottledRequestIsTriedAgain() async throws {
        let session = ScriptedResponses.session([
            (429, ["Retry-After": "0"], #"{"error":{"message":"Provider returned 429"}}"#),
            (200, [:], #"{"text":"Hallo"}"#),
        ])
        let text = try await Transcriber(session: session).transcribe(wav: Data("RIFF".utf8), apiKey: "k")

        #expect(text == "Hallo")
        #expect(ScriptedResponses.requests == 2)
    }

    @Test func itGivesUpAfterTheLastAttempt() async {
        let throttled = (429, ["Retry-After": "0"], "")
        let session = ScriptedResponses.session([throttled, throttled, throttled, (200, [:], #"{"text":"zu spät"}"#)])

        await #expect(throws: Transcriber.Failure.rateLimited) {
            try await Transcriber(session: session).transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        }
        #expect(ScriptedResponses.requests == 3)
    }

    @Test func otherFailuresAreNotRetried() async {
        let session = ScriptedResponses.session([(401, [:], ""), (200, [:], #"{"text":"nein"}"#)])

        await #expect(throws: Transcriber.Failure.unauthorized) {
            try await Transcriber(session: session).transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        }
        #expect(ScriptedResponses.requests == 1)
    }
}

@Test func theWaitComesFromTheProviderAndIsCapped() {
    let url = URL(string: "https://openrouter.ai")!
    let header = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "1.5"])!
    let none = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
    let body = Data(#"{"error":{"metadata":{"retry_after_seconds":3}}}"#.utf8)

    #expect(Transcriber.retryDelay(http: header, body: Data()) == 1.5)
    #expect(Transcriber.retryDelay(http: none, body: body) == 3)
    #expect(Transcriber.retryDelay(http: none, body: Data()) == 2)
    let long = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!
    #expect(Transcriber.retryDelay(http: long, body: Data()) == 5)
}
