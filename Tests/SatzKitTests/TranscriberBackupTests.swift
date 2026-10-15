import Foundation
import Testing
@testable import SatzKit

/// Answers requests from a script; a nil delay holds an answer until cancellation.
final class SlowResponses: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [(delay: TimeInterval?, status: Int, body: String)] = []
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var emitted: Set<Int> = []
    nonisolated(unsafe) private static var stopped: Set<Int> = []
    static var requests: Int { lock.withLock { starts } }
    static var emissions: Set<Int> { lock.withLock { emitted } }
    static var cancellations: Set<Int> { lock.withLock { stopped } }
    private var cancelled = false
    private var number = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.lock.withLock {
            Self.starts += 1
            number = Self.starts
            return Self.script.isEmpty ? (delay: TimeInterval?(0), status: 500, body: "") : Self.script.removeFirst()
        }
        guard let delay = next.delay else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard Self.lock.withLock({
                guard !cancelled else { return false }
                Self.emitted.insert(number)
                return true
            }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(next.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.withLock {
            cancelled = true
            Self.stopped.insert(number)
        }
    }

    static func transcriber(_ script: [(TimeInterval?, Int, String)], backupAfter: TimeInterval) -> Transcriber {
        lock.withLock {
            self.script = script.map { (delay: $0.0, status: $0.1, body: $0.2) }
            starts = 0
            emitted = []
            stopped = []
        }
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
        var transcriber = SlowResponses.transcriber([(nil, 200, #"{"text":"slow"}"#), (0, 200, #"{"text":"fast"}"#)], backupAfter: 0.2)
        // Only a hang guard: the first answer cannot win regardless of CPU load.
        transcriber.settings.timeout = 10
        let text = try await transcriber.transcribe(wav: Data("RIFF".utf8), apiKey: "k")
        #expect(text == "fast")
        #expect(SlowResponses.requests == 2)
        #expect(SlowResponses.emissions == [2])
        // URLSession can deliver stopLoading after its cancelled task returns.
        let deadline = ContinuousClock.now + .seconds(10)
        while !SlowResponses.cancellations.contains(1), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(SlowResponses.cancellations.contains(1))
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
