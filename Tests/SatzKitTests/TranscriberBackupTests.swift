import Foundation
import Testing
@testable import SatzKit

/// Answers requests from a script, each after its own delay.
final class SlowResponses: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [(delay: TimeInterval, status: Int, body: String)] = []
    nonisolated(unsafe) static var requests = 0
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let next = Self.script.isEmpty ? (delay: 0, status: 500, body: "") : Self.script.removeFirst()
        DispatchQueue.global().asyncAfter(deadline: .now() + next.delay) { [self] in
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(next.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { cancelled = true }

    static func transcriber(_ script: [(TimeInterval, Int, String)], backupAfter: TimeInterval) -> Transcriber {
        self.script = script.map { (delay: $0.0, status: $0.1, body: $0.2) }
        requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowResponses.self]
        var settings = Transcriber.Settings(provider: .openRouter)
        settings.backupAfter = backupAfter
        return Transcriber(settings: settings, session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized)
struct BackupTests {
    @Test func aSecondRequestAnswersWhenTheFirstIsSlow() async throws {
        let transcriber = SlowResponses.transcriber([(3, 200, #"{"text":"slow"}"#), (0, 200, #"{"text":"fast"}"#)], backupAfter: 0.2)
        let start = Date()
        let text = try await transcriber.transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        #expect(text == "fast")
        #expect(Date().timeIntervalSince(start) < 1.5)
        #expect(SlowResponses.requests == 2)
    }

    @Test func aQuickAnswerNeedsNoSecondRequest() async throws {
        let transcriber = SlowResponses.transcriber([(0, 200, #"{"text":"quick"}"#), (0, 200, #"{"text":"never"}"#)], backupAfter: 0.3)
        let text = try await transcriber.transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        try await Task.sleep(for: .seconds(0.5))
        #expect(text == "quick")
        #expect(SlowResponses.requests == 1)
    }

    @Test func aRejectedKeyFailsAtOnceWithoutASecondRequest() async {
        let transcriber = SlowResponses.transcriber([(0, 401, ""), (0, 200, #"{"text":"no"}"#)], backupAfter: 0.5)
        await #expect(throws: Transcriber.Failure.unauthorized) {
            try await transcriber.transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        }
        #expect(SlowResponses.requests == 1)
    }

    @Test func whenTheSecondFailsTheFirstMayStillAnswer() async throws {
        let transcriber = SlowResponses.transcriber([(0.6, 200, #"{"text":"late but fine"}"#), (0, 500, "")], backupAfter: 0.1)
        let text = try await transcriber.transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        #expect(text == "late but fine")
    }

    @Test func otherProvidersSendOnlyOnce() async throws {
        let transcriber = SlowResponses.transcriber([(0.6, 200, #"{"text":"one"}"#), (0, 200, #"{"text":"two"}"#)], backupAfter: 0.1)
        var settings = transcriber.settings
        settings.format = .multipart
        let single = Transcriber(settings: settings, session: URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SlowResponses.self]
            return configuration
        }()))
        #expect(try await single.transcribe(wav: Data("RIFF".utf8), apiKey: "k") == "one")
        #expect(SlowResponses.requests == 1)
    }

    @Test func whenBothFailTheFirstFailureIsReported() async {
        let transcriber = SlowResponses.transcriber([(0.4, 503, ""), (0, 502, "")], backupAfter: 0.1)
        await #expect(throws: Transcriber.Failure.server(status: 502, message: nil)) {
            try await transcriber.transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        }
    }
}
