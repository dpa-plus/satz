import Foundation
import Testing
@testable import SatzKit

// Third Codex audit (14.10.2026), the cleanup client.
//
// Provider error text in the log: a 400 whose message quotes the request (the
// dictation, the key) reached the log through `CleanupResult.detail`. Only the
// status and the error's labels may.
// A cancelled run: a discarded dictation's cleanup sends nothing more and
// leaves no time behind that could pass for a measurement.
//
// A real HTTP server on 127.0.0.1 (`StandInServer`), never a provider.

private func standIn(_ server: StandInServer, key: String? = nil) -> CleanupJob {
    CleanupJob(provider: .custom, model: CleanupCatalog.model("stand-in", for: .custom, listing: nil),
               address: server.baseURL.absoluteString + "/v1", key: key, level: .light)
}

private func answer(_ text: String) -> StandInServer.Answer {
    .init(body: #"{"choices":[{"message":{"role":"assistant","content":"\#(text)"}}]}"#)
}

private let said = "bitte überweise 4711 euro an max mustermann"
private let key = "sk-test-key-not-real-0123456789"

@Suite struct CodexR3ErrorLabelsTests {

    private func detail(_ json: String, key: String? = nil) -> String? { CleanupRequest.errorDetail(in: Data(json.utf8), key: key) }

    @Test func theTypeAndCodeOfEachFamilysError() {
        // OpenAI and the compatible ones.
        #expect(detail(#"{"error":{"message":"x","type":"invalid_request_error","code":"model_not_found","param":null}}"#)
                == "type=invalid_request_error, code=model_not_found")
        // Anthropic.
        #expect(detail(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == "type=overloaded_error")
        // Google: a number for the code, a word for the status.
        #expect(detail(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#)
                == "code=400, status=INVALID_ARGUMENT")
        // OpenRouter: a number, and a message that is not logged.
        #expect(detail(#"{"error":{"code":402,"message":"Insufficient credits"}}"#) == "code=402")
    }

    @Test func noMessageAndNothingThatIsNotAShortToken() {
        #expect(detail(#"{"error":{"message":"Invalid input: \#(said). Account \#(key)"}}"#) == nil)
        #expect(detail(#"{"error":"Invalid input: \#(said)"}"#) == nil)
        #expect(detail(#"{"message":"Invalid input: \#(said)"}"#) == nil)
        // A sentence, a token that is too long, an empty one.
        #expect(detail(#"{"error":{"type":"Invalid input: \#(said)","code":"\#(String(repeating: "a", count: 65))","status":""}}"#) == nil)
        // A boolean, a list, an object, a null, non-ASCII, a space.
        #expect(detail(#"{"error":{"type":true,"code":["INVALID_ARGUMENT"],"status":{"a":1}}}"#) == nil)
        #expect(detail(#"{"error":{"type":null,"code":"überweise","status":"a b"}}"#) == nil)
        // One good value beside a bad one: the good one.
        #expect(detail(#"{"error":{"type":"Invalid input: \#(said)","code":"rate_limit_exceeded"}}"#) == "code=rate_limit_exceeded")
        // Not an error body at all.
        #expect(detail("not json") == nil && detail("[]") == nil && detail("") == nil)
    }

    /// A token that is the key, or holds it, is not logged either, even
    /// though it looks like a code.
    @Test func aValueThatHoldsTheKeyIsLeftOut() {
        let body = #"{"error":{"type":"invalid_request_error","code":"\#(key)","status":"bad_\#(key)_key"}}"#
        #expect(detail(body, key: key) == "type=invalid_request_error")
        #expect(detail(body, key: "  \(key)\n") == "type=invalid_request_error")
        // Without a key to compare with, the token is only a token.
        #expect(detail(body, key: nil)?.contains(key) == true)
        // A key too short to tell from a word does not hide the word.
        #expect(detail(#"{"error":{"code":"not_found"}}"#, key: "found") == "code=not_found")
    }
}

@Suite(.serialized) struct CodexR3ProviderErrorLogTests {

    /// Codex's privacy probe: a 400 that echoes the dictation and the key.
    @Test func aProviderThatQuotesTheRequestDoesNotReachTheLog() async throws {
        let body = #"{"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Invalid input: \#(said). Account \#(key)"}}"#
        let server = try await StandInServer.start([.init(status: 400, body: body)])
        defer { server.stop() }
        let result = await CleanupClient().run(standIn(server, key: key), text: said)
        #expect(result.failure == .refused(400) && result.text == said)
        #expect(result.detail == "status 400: type=invalid_request_error, code=context_length_exceeded")
        let logged = result.detail ?? ""
        #expect(!logged.contains("4711") && !logged.contains("mustermann") && !logged.contains(key) && !logged.contains("Invalid input"))
    }

    @Test func theMessageIsNotLoggedWhateverTheStatus() async throws {
        for status in [401, 402, 404, 429, 500, 503] {
            let server = try await StandInServer.start([.init(status: status, body: #"{"error":{"message":"echo: \#(said) \#(key)"}}"#)])
            defer { server.stop() }
            let result = await CleanupClient().run(standIn(server, key: key), text: said)
            #expect(result.detail == "status \(status)", "\(status)")
        }
    }

    /// The retry reads the message to see which extra the provider refuses;
    /// reading it is not logging it. The second answer's detail is as safe.
    @Test func theRetryStillReadsTheMessageButTheLogDoesNot() async throws {
        let server = try await StandInServer.start([
            .init(status: 400, body: #"{"error":{"type":"invalid_request_error","message":"temperature is not supported. You said: \#(said)"}}"#),
            .init(status: 400, body: #"{"error":{"type":"invalid_request_error","message":"still no. You said: \#(said)"}}"#),
        ])
        defer { server.stop() }
        let result = await CleanupClient().run(standIn(server, key: key), text: said)
        #expect(server.requests.count == 2, "the temperature was taken out and asked again")
        #expect(result.detail == "status 400: type=invalid_request_error")
    }

    @Test func anAnswerThatIsNoAnswerKeepsItsOwnShortDetail() async throws {
        let server = try await StandInServer.start([.init(body: "<html>\(said)</html>")])
        defer { server.stop() }
        let result = await CleanupClient().run(standIn(server), text: said)
        #expect(result.failure == .providerError && result.detail == "status 200: unreadable answer")
    }
}

@Suite(.serialized) struct CodexR3CancelledCleanupTests {

    /// Waits for `condition`, up to two seconds.
    private func until(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aCancelledResultIsTheOriginalWithoutATimeOrAPrice() {
        let result = CleanupResult.cancelled("hallo welt")
        #expect(result.text == "hallo welt" && result.cleaned == nil && result.failure == .notReachable && result.detail == "cancelled")
        #expect(result.seconds == nil && result.dollars == nil && !result.answered)
    }

    @Test func aRunCancelledBeforeItStartsSendsNothing() async throws {
        let server = try await StandInServer.start([answer("Hallo Welt, wie geht es dir?")])
        defer { server.stop() }
        let job = standIn(server)
        let run = Task {
            while !Task.isCancelled { await Task.yield() }
            return await CleanupClient().run(job, text: "hallo welt wie geht es dir")
        }
        run.cancel()
        let result = await run.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(result.detail == "cancelled" && result.text == "hallo welt wie geht es dir" && result.seconds == nil)
        #expect(server.requests.isEmpty)
    }

    /// Cancelled while the provider thinks: back at once, no time, and when
    /// the provider answers with something that would be asked again (a 400
    /// that names the temperature), the second request is never made.
    @Test func aRunCancelledWhileItWaitsAsksNothingMore() async throws {
        let server = try await StandInServer.start([
            .init(status: 400, body: #"{"error":{"message":"temperature is not supported"}}"#, delay: 0.6),
            answer("Hallo Welt, wie geht es dir?"),
        ])
        defer { server.stop() }
        let job = standIn(server)
        let run = Task { await CleanupClient().run(job, text: "hallo welt wie geht es dir") }
        await until { server.requests.count == 1 }
        let cancelledAt = Date()
        run.cancel()
        let result = await run.value
        #expect(Date().timeIntervalSince(cancelledAt) < 0.4, "does not wait for the provider")
        #expect(result.failure == .notReachable && result.detail == "cancelled")
        #expect(result.seconds == nil && result.dollars == nil && !result.answered)
        // Past the point where the 400 would have been answered and asked again.
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(server.requests.count == 1)
    }

    @Test func aRunThatWasNotCancelledIsMeasuredAsBefore() async throws {
        let server = try await StandInServer.start([answer("Hallo Welt, wie geht es dir?")])
        defer { server.stop() }
        let result = await CleanupClient().run(standIn(server), text: "hallo welt wie geht es dir")
        #expect(result.failure == nil && result.answered && result.seconds != nil)
    }
}
