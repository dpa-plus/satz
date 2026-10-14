import Foundation
import Network
import Testing
@testable import SatzKit

// Fixes from Codex's bug hunt of 14.10.2026, Mac side of the cloud providers:
// F13 (a total deadline), F14 (which addresses may be used), and from its
// section 4 (redirects, Google's storage flag, answer shape and size limit).
// Every server here is a stand-in on 127.0.0.1; no provider is called.

private let audio = Data("RIFF....WAVEfmt fake audio bytes".utf8)

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - A server whose answer drips in

/// Answers the first request with a valid JSON body written one byte at a
/// time, `gap` seconds apart: every gap is shorter than any timeout under
/// test, so only a limit on the whole call can end it. Notes whether the
/// client was still there for the last byte.
private final class TrickleServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "satz.trickle")
    private let lock = NSLock()
    private var finished = false
    private var gone = false
    private let letters: Int
    private let gap: TimeInterval
    private(set) var port: UInt16 = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    /// The whole body went out: nobody hung up on the way.
    var sentEverything: Bool { lock.withLock { finished } }
    /// The client closed the connection before the end.
    var clientHungUp: Bool { lock.withLock { gone } }

    private init(letters: Int, gap: TimeInterval) throws {
        self.letters = letters
        self.gap = gap
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(letters: Int, gap: TimeInterval) async throws -> TrickleServer {
        let server = try TrickleServer(letters: letters, gap: gap)
        server.listener.newConnectionHandler = { connection in server.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = FirstTime()
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready where once.isIt(): continuation.resume()
                case .failed(let error) where once.isIt(): continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        server.port = server.listener.port?.rawValue ?? 0
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    /// Until the headers and as many body bytes as Content-Length says.
    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, finished, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex ..< end.lowerBound], as: UTF8.self).lowercased()
                let length = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    line.hasPrefix("content-length:") ? Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                if buffer[end.upperBound...].count >= length { return answer(connection) }
            }
            if error != nil || finished { connection.cancel() } else { readRequest(connection, buffer: buffer) }
        }
    }

    private func answer(_ connection: NWConnection) {
        let opening = #"{"text":""#
        let length = opening.utf8.count + letters + 2
        let head = "HTTP/1.1 200 Stand-in\r\nContent-Type: application/json\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
        // A hung-up client shows as an end of the stream here, or as a failed write below.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, complete, error in
            if complete || error != nil { lock.withLock { gone = true } }
        }
        connection.send(content: Data((head + opening).utf8), completion: .contentProcessed { _ in })
        drip(connection, left: letters)
    }

    private func drip(_ connection: NWConnection, left: Int) {
        queue.asyncAfter(deadline: .now() + gap) { [self] in
            if lock.withLock({ gone }) { return connection.cancel() }
            let last = left == 0
            // The connection is closed only once the last byte has gone out.
            connection.send(content: Data((last ? "\"}" : "x").utf8), completion: .contentProcessed { [self] error in
                if error != nil { lock.withLock { gone = true } }
                if last { connection.cancel() }
            })
            if last {
                lock.withLock { finished = true }
            } else {
                drip(connection, left: left - 1)
            }
        }
    }
}

private final class FirstTime: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func isIt() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

private func quickly(_ settings: inout Transcriber.Settings, timeout: TimeInterval) {
    settings.timeout = timeout
    settings.attempts = 1
    settings.backupAfter = nil
}

/// Waits for `condition` a little: the server learns of a closed connection a moment later.
private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

// MARK: - F13: one deadline for the whole call

@Suite(.serialized)
struct TotalDeadlineTests {

    @Test func aSlowlyDrippingAnswerEndsAtTheDeadlineAndTheConnectionIsDropped() async throws {
        // 40 bytes, a tenth of a second apart: four seconds in all, and never
        // a pause near the half second given. URLRequest.timeoutInterval
        // alone let this through (a 30 s limit held for 34 s).
        let server = try await TrickleServer.start(letters: 40, gap: 0.1)
        defer { server.stop() }
        var settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: server.baseURL)
        quickly(&settings, timeout: 0.5)

        let started = Date()
        await #expect(throws: Transcriber.Failure.timedOut) {
            try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: "k")
        }
        let took = Date().timeIntervalSince(started)
        #expect(took >= 0.45 && took < 2.0, "ended after \(took) s")

        // The work was cancelled, not just left running behind the error.
        #expect(await eventually { server.clientHungUp })
        #expect(!server.sentEverything)
    }

    @Test func theLimitIsTheSameAsBeforeAndAHealthyAnswerIsNotCutShort() async throws {
        // Half a second of dripping under a two second limit: a success.
        let server = try await TrickleServer.start(letters: 5, gap: 0.1)
        defer { server.stop() }
        var settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: server.baseURL)
        quickly(&settings, timeout: 2)

        let text = try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: "k")
        #expect(text == "xxxxx")
        // The request still carries the number the deadline is made from.
        #expect(Transcriber(settings: settings).makeRequest(wav: audio, apiKey: "k").timeoutInterval == 2)
    }

    @Test func aLongRecordingKeepsItsExtraTime() {
        // Five minutes of audio: 30 s plus a second for every two seconds of it.
        let fiveMinutes = Data(count: 44 + 300 * 32_000)
        #expect(Transcriber.Settings().timeout(for: fiveMinutes) == 180)
        // The request carries the same number, and the deadline is made from it.
        var settings = Transcriber.Settings()
        settings.timeout = 30
        #expect(Transcriber(settings: settings).makeRequest(wav: fiveMinutes, apiKey: "k").timeoutInterval == 180)
    }

    @Test func aFiveMinuteRecordingStillGetsThroughOnAHalfMegabitUplink() {
        // The call is held to this total, upload included (F13), so the upload
        // has to fit: 9.6 MB at 0.5 Mbit/s take 153.6 s. A second per four
        // seconds of audio gave 105 s and cut it off with the audio nearly
        // there; the answer still needs a moment after the last byte.
        let fiveMinutes = Data(count: 44 + 300 * 32_000)
        let upload = Double(fiveMinutes.count) * 8 / 500_000
        let allowed = Transcriber.Settings().timeout(for: fiveMinutes)
        #expect(upload > 150 && upload < 155)
        #expect(allowed - upload > 20, "\(allowed) s allowed for \(upload) s of upload")
        // Shorter recordings are not worse off, and none gets less than the base.
        for seconds in [0, 5, 30, 60, 120, 300, 600] {
            let wav = Data(count: 44 + seconds * 32_000)
            let uplink = Double(wav.count) * 8 / 500_000
            #expect(Transcriber.Settings().timeout(for: wav) >= 30)
            #expect(Transcriber.Settings().timeout(for: wav) - uplink > 15, "\(seconds) s of audio")
        }
    }

    @Test func aStalledAnswerStillTimesOut() async throws {
        // The body stops after the headers: the old inactivity limit and the
        // new total both apply, and the answer is the same one.
        let server = try await TrickleServer.start(letters: 0, gap: 30)
        defer { server.stop() }
        var settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: server.baseURL)
        quickly(&settings, timeout: 0.4)
        await #expect(throws: Transcriber.Failure.timedOut) {
            try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: "k")
        }
    }

    @Test func cancellingTheCallEndsItAtOnceAndDropsTheConnection() async throws {
        let server = try await TrickleServer.start(letters: 100, gap: 0.1)
        defer { server.stop() }
        var settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: server.baseURL)
        quickly(&settings, timeout: 30)
        let call = Task { try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: "k") }
        try await Task.sleep(for: .milliseconds(300))

        let started = Date()
        call.cancel()
        _ = await call.result
        #expect(Date().timeIntervalSince(started) < 1.0)
        #expect(await eventually { server.clientHungUp })
    }
}

// MARK: - Redirects keep the key where it was sent

@Suite(.serialized)
struct RedirectTests {

    private func settings(_ provider: Provider, at server: StandInServer) -> Transcriber.Settings {
        var settings = Transcriber.Settings(provider: provider, model: "m", customBaseURL: server.baseURL)
        settings.baseURL = server.baseURL
        settings.attempts = 1
        settings.backupAfter = nil
        return settings
    }

    @Test(arguments: [Provider.custom, .openAI, .openRouter, .microsoft, .google])
    func aRedirectToAnotherOriginIsNotFollowedAndNothingIsForwarded(provider: Provider) async throws {
        // The other side answers under another name and port, like Codex's
        // 127.0.0.1 to localhost: a request there would carry the key header.
        let elsewhere = try await StandInServer.start([.init(body: #"{"text":"stolen","combinedPhrases":[{"text":"stolen"}],"output_text":"stolen"}"#)])
        defer { elsewhere.stop() }
        let origin = try await StandInServer.start([
            .init(status: 307, headers: ["Location": "http://localhost:\(elsewhere.port)/stolen"], body: ""),
        ])
        defer { origin.stop() }

        do {
            _ = try await Transcriber(settings: settings(provider, at: origin)).transcribe(wav: audio, apiKey: "SYNTHETIC-KEY")
            Issue.record("followed the redirect")
        } catch let failure as Transcriber.Failure {
            #expect(failure == .redirected)
        }
        #expect(origin.requests.count == 1)
        #expect(elsewhere.requests.isEmpty, "the other origin got \(elsewhere.requests.map(\.target))")
    }

    @Test func aRedirectWithinTheSameOriginIsStillFollowed() async throws {
        // Google's key is a header of its own, which a redirect keeps; the
        // point is that staying on the origin is not refused.
        let origin = try await StandInServer.start([
            .init(status: 307, headers: ["Location": "/v1beta/moved"], body: ""),
            .init(body: #"{"output_text":"angekommen"}"#),
        ])
        defer { origin.stop() }
        let text = try await Transcriber(settings: settings(.google, at: origin)).transcribe(wav: audio, apiKey: "SYNTHETIC-KEY")

        #expect(text == "angekommen")
        #expect(origin.requests.map(\.target) == ["/interactions", "/v1beta/moved"])
        #expect(origin.requests.last?.headers["x-goog-api-key"] == "SYNTHETIC-KEY")
        #expect(origin.requests.last?.body.isEmpty == false)
    }

    @Test func aRedirectWithinTheSameOriginCarriesABearerKeyOn() async throws {
        // OpenAI, Groq and most custom endpoints send the key as Authorization,
        // which URLSession drops on a redirect: the second request would be
        // refused with a 401 the user cannot explain. Same origin, so the
        // key may go on.
        let origin = try await StandInServer.start([
            .init(status: 307, headers: ["Location": "/v1/audio/transcriptions/"], body: ""),
            .init(body: #"{"text":"angekommen"}"#),
        ])
        defer { origin.stop() }
        let text = try await Transcriber(settings: settings(.custom, at: origin)).transcribe(wav: audio, apiKey: "SYNTHETIC-KEY")

        #expect(text == "angekommen")
        #expect(origin.requests.map(\.target) == ["/audio/transcriptions", "/v1/audio/transcriptions/"])
        #expect(origin.requests.last?.headers["authorization"] == "Bearer SYNTHETIC-KEY")
        #expect(origin.requests.last?.body.isEmpty == false)
    }

    @Test func originsAreComparedBySchemeHostAndPort() {
        let same = { (a: String, b: String) in Transcriber.StaysOnOrigin.sameOrigin(URL(string: a), URL(string: b)) }
        #expect(same("https://api.example.org/v1/a", "https://api.example.org/other"))
        #expect(same("https://API.example.org/v1", "HTTPS://api.example.org:443/x"))
        #expect(same("http://127.0.0.1:8080/a", "http://127.0.0.1:8080/b"))
        #expect(!same("https://api.example.org/v1", "https://evil.example.org/v1"))
        #expect(!same("https://api.example.org/v1", "https://api.example.org:8443/v1"))
        // A downgrade is another origin too.
        #expect(!same("https://api.example.org/v1", "http://api.example.org/v1"))
        #expect(!same("http://127.0.0.1:8080/a", "http://localhost:8080/a"))
        #expect(!Transcriber.StaysOnOrigin.sameOrigin(nil, URL(string: "https://api.example.org")))
        #expect(!Transcriber.StaysOnOrigin.sameOrigin(URL(string: "https://api.example.org"), nil))
    }

    @Test func theRefusedRedirectIsExplainedInBothLanguagesWithoutAnEmDash() {
        for status in [301, 302, 303, 307, 308] {
            #expect(Transcriber.failure(status: status, body: Data()) == .redirected, "\(status)")
        }
        // The long explanation is for the log (`message`); the card has `short`.
        let message = Transcriber.Failure.redirected.message
        #expect(["Der Anbieter verweist auf eine andere Adresse. Die Adresse prüfen.",
                 "The provider points to another address. Check the address."].contains(message))
        #expect(!message.contains("\u{2014}"))
        // A plain answer is still the plain one.
        #expect(Transcriber.failure(status: 404, body: Data()) == .server(status: 404, message: nil))
        // Asking again does not help until the address is changed, but it is not forbidden.
        #expect(Transcriber.Failure.redirected.retryHelps)
    }

    @Test func aRedirectToAnotherPortOnTheSameHostIsAnotherOrigin() async throws {
        // Same host name, other port: another service, and the key header goes with the request.
        let elsewhere = try await StandInServer.start([.init(body: #"{"text":"stolen"}"#)])
        defer { elsewhere.stop() }
        let origin = try await StandInServer.start([
            .init(status: 308, headers: ["Location": "http://127.0.0.1:\(elsewhere.port)/stolen"], body: ""),
        ])
        defer { origin.stop() }
        await #expect(throws: Transcriber.Failure.redirected) {
            try await Transcriber(settings: settings(.custom, at: origin)).transcribe(wav: audio, apiKey: "SYNTHETIC-KEY")
        }
        #expect(elsewhere.requests.isEmpty)
    }

    @Test func threeHopsWithinTheOriginAreFollowedAndTheFourthIsRefused() async throws {
        // Three redirects and then the answer: the longest chain that goes through.
        let three = try await StandInServer.start([
            .init(status: 307, headers: ["Location": "/a"], body: ""),
            .init(status: 307, headers: ["Location": "/b"], body: ""),
            .init(status: 307, headers: ["Location": "/c"], body: ""),
            .init(body: #"{"text":"angekommen"}"#),
        ])
        defer { three.stop() }
        let text = try await Transcriber(settings: settings(.custom, at: three)).transcribe(wav: audio, apiKey: "SYNTHETIC-KEY")
        #expect(text == "angekommen")
        #expect(three.requests.count == 4)

        // A fourth redirect is one too many, whatever stands behind it: a loop ends.
        let four = try await StandInServer.start([
            .init(status: 307, headers: ["Location": "/a"], body: ""),
            .init(status: 307, headers: ["Location": "/b"], body: ""),
            .init(status: 307, headers: ["Location": "/c"], body: ""),
            .init(status: 307, headers: ["Location": "/d"], body: ""),
            .init(body: #"{"text":"never"}"#),
        ])
        defer { four.stop() }
        await #expect(throws: Transcriber.Failure.redirected) {
            try await Transcriber(settings: settings(.custom, at: four)).transcribe(wav: audio, apiKey: "SYNTHETIC-KEY")
        }
        #expect(four.requests.count == 4, "went on to \(four.requests.map(\.target))")
    }

    @Test func aRedirectLoopOnOneAddressEndsAfterThreeHops() async throws {
        // Every answer points back to the same path.
        let loop = try await StandInServer.start(Array(repeating: .init(status: 302, headers: ["Location": "/audio/transcriptions"], body: ""), count: 20))
        defer { loop.stop() }
        await #expect(throws: Transcriber.Failure.redirected) {
            try await Transcriber(settings: settings(.custom, at: loop)).transcribe(wav: audio, apiKey: "SYNTHETIC-KEY")
        }
        #expect(loop.requests.count == 4)
    }
}

// MARK: - F14: which addresses a key may go to

@Suite(.serialized)
struct AddressTests {

    private static let unusable = [
        "ftp://example.invalid/v1", "file://example.invalid/tmp", "ws://localhost:8080/v1", "//example.invalid/v1",
        "example.invalid/v1", "localhost:8080/v1", "https://", "https:///v1", "http:///v1",
        // Plain http is for one's own network only, and a name that merely starts like it is not that.
        "http://example.invalid/v1", "http://localhost.example.invalid/v1", "http://127.0.0.1.example.invalid/v1",
        "http://8.8.8.8/v1", "http://192.168.1.5.example.invalid/v1",
        "", "   ", "not an address",
    ]

    @Test(arguments: unusable)
    func customRefusesAddressesThatCannotBeUsed(address: String) {
        // Nothing typed asks for an address; one that is typed is refused, and told why.
        let expected: ProviderReadiness.Need = address.trimmingCharacters(in: .whitespaces).isEmpty ? .address : .addressRefused
        #expect(ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: address, model: "whisper-1") == [expected], "\(address)")
        #expect(!ProviderReadiness.hasUsableAddress(address))
        #expect(ProviderReadiness.sendableAddress(address) == nil)
    }

    @Test(arguments: [
        "https://example.invalid/v1", " https://example.invalid/v1\n", "HTTPS://Example.invalid/v1", "https://localhost:8443/v1",
        "http://localhost:8080/v1", "http://LOCALHOST/v1", "http://127.0.0.1:9000/v1", "http://[::1]:8080/v1",
    ])
    func customTakesHttpsAndHttpToThisComputer(address: String) {
        #expect(ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: address, model: "whisper-1").isEmpty, "\(address)")
        #expect(ProviderReadiness.sendableAddress(address) != nil)
    }

    @Test func theSchemeIsWrittenOneWayAndTheRestIsKept() {
        #expect(ProviderReadiness.sendableAddress("HTTPS://Example.invalid:8443/v1/")?.absoluteString == "https://Example.invalid:8443/v1/")
        #expect(ProviderReadiness.sendableAddress("  http://[::1]:8080/v1 ")?.absoluteString == "http://[::1]:8080/v1")
    }

    @Test(arguments: unusable)
    func whatIsSentIsWhatWasCheckedSoAnUnusableAddressGoesNowhere(address: String) throws {
        // Preferences hands the text over as a URL; the settings apply the
        // very same rule, so an address that failed above is not sent to.
        guard let url = URL(string: address) else { return }
        let settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: url)
        #expect(settings.baseURL.host == "address-missing.invalid", "\(address) became \(settings.baseURL)")
    }

    @Test func anAddressThatPassedIsTheOneTheRequestGoesTo() throws {
        for address in ["HTTPS://Example.invalid/v1", " http://localhost:8080/v1 "] {
            let checked = try #require(ProviderReadiness.sendableAddress(address))
            let settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: URL(string: address.trimmingCharacters(in: .whitespaces)))
            #expect(settings.baseURL == checked)
            let request = Transcriber(settings: settings).makeRequest(wav: audio, apiKey: "k")
            #expect(request.url?.absoluteString == checked.absoluteString + "/audio/transcriptions")
        }
    }

    @Test func aModelServerOnThisComputerStillWorksOverPlainHttp() async throws {
        let server = try await StandInServer.start([.init(body: #"{"text":"lokal"}"#)])
        defer { server.stop() }
        let settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: server.baseURL)
        let text = try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: "k")
        #expect(text == "lokal")
        #expect(server.requests.count == 1)
    }

    // Microsoft's own address.

    @Test(arguments: [
        "ftp://x.example.org", "file:///tmp/x", "//x.cognitiveservices.azure.com", "//x.cognitiveservices.azure.com/v1",
        "http://x.cognitiveservices.azure.com", "http://localhost.example.org", "http://8.8.8.8:8080", "https://localhost",
        "https://", "https:///x", "nonsense", "wss://x.example.org",
    ])
    func microsoftRefusesAddressesThatCannotBeUsed(address: String) {
        #expect(MicrosoftSpeech.endpointURL(address) == nil, "\(address)")
        #expect(MicrosoftSpeech.baseURL(region: "northeurope", endpoint: address) == nil)
        #expect(ProviderReadiness.missing(.microsoft, hasKey: true, customBaseURL: "", model: "", microsoftEndpoint: address) == [.addressRefused])
        // The key does not go to the region's host instead.
        let settings = Transcriber.Settings(provider: .microsoft, microsoftRegion: "northeurope", microsoftEndpoint: address)
        #expect(settings.baseURL.host == "address-missing.invalid")
    }

    @Test func microsoftTakesHttpsAndHttpToThisComputer() {
        let url = { (text: String) in MicrosoftSpeech.endpointURL(text)?.absoluteString }
        #expect(url("https://x.cognitiveservices.azure.com/") == "https://x.cognitiveservices.azure.com")
        #expect(url("x.cognitiveservices.azure.com") == "https://x.cognitiveservices.azure.com")
        #expect(url("HTTPS://x.cognitiveservices.azure.com:8443/speechtotext") == "https://x.cognitiveservices.azure.com:8443")
        // A stand-in server in a test, as on Windows and Linux.
        #expect(url("http://localhost:8080") == "http://localhost:8080")
        #expect(url("http://127.0.0.1:9000/x") == "http://127.0.0.1:9000")
        #expect(url("http://[::1]:8080") == "http://[::1]:8080")
        #expect(ProviderReadiness.missing(.microsoft, hasKey: true, customBaseURL: "", model: "", microsoftEndpoint: "http://localhost:8080").isEmpty)
    }

    @Test func microsoftsRequestGoesToTheStandInOnThisComputer() async throws {
        let server = try await StandInServer.start([.init(body: #"{"combinedPhrases":[{"text":"hallo"}]}"#)])
        defer { server.stop() }
        let settings = Transcriber.Settings(provider: .microsoft, microsoftEndpoint: "http://127.0.0.1:\(server.port)")
        let text = try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: "k")
        #expect(text == "hallo")
        #expect(server.requests.first?.headers["ocp-apim-subscription-key"] == "k")
    }
}

// MARK: - Google: storage, answer shape and size

@Suite(.serialized)
struct GoogleHardeningTests {

    @Test func theInteractionIsNotStoredAtGoogle() throws {
        let request = Transcriber(settings: Transcriber.Settings(provider: .google)).makeRequest(wav: audio, apiKey: "k")
        let raw = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(raw.contains(#""store":false"#))
        #expect(try json(try #require(request.httpBody))["store"] as? Bool == false)
    }

    @Test func theStorageFlagReachesTheServer() async throws {
        let server = try await StandInServer.start([.init(body: #"{"steps":[{"type":"model_output","content":[{"type":"text","text":"ok"}]}]}"#)])
        defer { server.stop() }
        var settings = Transcriber.Settings(provider: .google)
        settings.baseURL = server.baseURL
        _ = try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: "k")
        let body = try json(try #require(server.requests.first).body)
        #expect(body["store"] as? Bool == false)
    }

    @Test func textInBothOutputTextAndStepsIsSaidOnce() {
        let text = { (json: String) in GeminiTranscribe.text(in: Data(json.utf8)) }
        let twice = #"{"output_text": "Hallo Welt.", "steps": [{"type": "model_output", "content": [{"type": "text", "text": "Hallo Welt."}]}]}"#
        #expect(text(twice) == "Hallo Welt.")
        // Every shape that can sit next to another.
        #expect(text(#"{"steps": [{"type": "model_output", "content": [{"type": "text", "text": "Eins."}]}], "outputs": [{"type": "text", "text": "Eins."}]}"#) == "Eins.")
        #expect(text(#"{"output_text": "Eins.", "candidates": [{"content": {"parts": [{"text": "Eins."}]}}]}"#) == "Eins.")
        // Several items of one shape still make one sentence.
        #expect(text(#"{"steps": [{"type": "model_output", "content": [{"type": "text", "text": "Eins."}, {"type": "text", "text": "Zwei."}]}], "output_text": "Eins. Zwei."}"#) == "Eins. Zwei.")
        // A shape without words hands over to the next one.
        #expect(text(#"{"steps": [{"type": "thought", "content": [{"type": "text", "text": "denkt"}]}], "output_text": "Gesagt."}"#) == "Gesagt.")
        #expect(text(#"{"steps": [], "output_text": "Gesagt."}"#) == "Gesagt.")
        // Nothing said anywhere is an empty answer, a non-answer still nil.
        #expect(text(#"{"steps": [], "output_text": ""}"#) == "")
        #expect(text(#"{"unrelated": true}"#) == nil)
    }

    @Test func theRequestSizeIsTheSizeOfTheBodyToTheByte() throws {
        let vocabularies: [[String]] = [
            [], ["Kubernetes", "Grafana"], [String(repeating: "\\", count: 5_000)], ["say \"hi\"", "a/b/c"],
            ["tab\there", "line\nbreak", "\u{1}\u{1f}", "back\\slash"], ["Ünïcödé", "日本語", "👩🏽‍💻"],
            (0 ..< 1_200).map { "wort\($0)" },
        ]
        for words in vocabularies {
            for length in [0, 1, 2, 3, 4, 100, 12_345] {
                for removesFillers in [true, false] {
                    var settings = Transcriber.Settings(provider: .google, model: "models/gemini-3.5-transcribe")
                    settings.vocabulary = words
                    settings.removesFillers = removesFillers
                    let wav = Data(count: length)
                    let sent = try #require(Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k").httpBody)
                    let counted = GeminiTranscribe.requestSize(wav: wav, model: settings.model, vocabulary: words, removesFillers: removesFillers)
                    #expect(counted == sent.count, "\(words.count) words, \(length) bytes: counted \(counted), sent \(sent.count)")
                }
            }
        }
    }

    @Test func escapingInTheVocabularyCountsTowardsTheLimit() async throws {
        // Codex's case: 5 000 backslashes are 10 000 bytes of JSON, and the
        // old count (one byte each) let 20 003 537 bytes go out.
        let wav = Data(count: 14_995_000)
        let words = [String(repeating: "\\", count: 5_000)]
        var settings = Transcriber.Settings(provider: .google)
        settings.vocabulary = words
        let sent = try #require(Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k").httpBody)
        #expect(sent.count > GeminiTranscribe.requestLimit)
        #expect(GeminiTranscribe.isTooLarge(wav: wav, vocabulary: words))
        // The same recording with a vocabulary that fits is sent.
        #expect(!GeminiTranscribe.isTooLarge(wav: wav, vocabulary: ["Kubernetes"]))

        // And refused before anything goes out.
        let server = try await StandInServer.start([.init(body: #"{"output_text":"never"}"#)])
        defer { server.stop() }
        settings.baseURL = server.baseURL
        await #expect(throws: Transcriber.Failure.tooLarge) {
            try await Transcriber(settings: settings).transcribe(wav: wav, apiKey: "k")
        }
        #expect(server.requests.isEmpty)
    }

    @Test func theLimitIsDecidedByTheBodyThatWouldBeSent() throws {
        // On both sides of the limit, with a vocabulary that is mostly escapes.
        let wav = Data(count: 14_990_000)
        func decided(backslashes: Int) throws -> (tooLarge: Bool, sent: Int) {
            var settings = Transcriber.Settings(provider: .google)
            settings.vocabulary = [String(repeating: "\\", count: backslashes)]
            let sent = try #require(Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k").httpBody).count
            return (GeminiTranscribe.isTooLarge(wav: wav, vocabulary: settings.vocabulary), sent)
        }
        // 14 990 000 bytes are 19 986 668 of base64; the rest of the room is for the vocabulary.
        let room = GeminiTranscribe.requestLimit - (try decided(backslashes: 0).sent)
        for backslashes in [room / 2 - 5, room / 2, room / 2 + 5] {
            let result = try decided(backslashes: backslashes)
            #expect(result.tooLarge == (result.sent > GeminiTranscribe.requestLimit), "\(backslashes) backslashes: \(result)")
        }
    }
}
