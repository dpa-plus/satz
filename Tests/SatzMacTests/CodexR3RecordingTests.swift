import AppKit
import Foundation
import Network
import SatzKit
import SwiftUI
import Testing
@testable import SatzMac

// Codex's third bug hunt (14.10.), the session's side. I-2: a microphone gone
// for good left the card "listening" while every word after it was lost; now
// the card pauses, says "Mikrofon getrennt", keeps what was heard, and going
// on opens the input there is now. F07 on the Mac: a discard while cleaning
// up must stop the request itself, not only drop its answer.
//
// The microphone is a stand-in that can be unplugged; transcription and
// cleanup go to a real HTTP server on 127.0.0.1. Never the user's keys,
// preferences, history or a real provider.

// MARK: - A server on this computer

private final class StandIn: @unchecked Sendable {
    struct Answer {
        var status = 200
        var body: String
        /// Seconds the answer is held back, as a slow model would.
        var hold: TimeInterval = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "satz.codexr3.standin")
    private let lock = NSLock()
    private var script: [Answer]
    private var bodies: [Data] = []
    private var hangUps: [Date] = []
    private var answered = 0
    private(set) var port: UInt16 = 0

    var requests: [Data] { lock.withLock { bodies } }
    /// When a client gave up on an answer that was being held back.
    var hungUp: [Date] { lock.withLock { hangUps } }
    var answers: Int { lock.withLock { answered } }
    var base: String { "http://127.0.0.1:\(port)/v1" }

    private init(script: [Answer]) throws {
        self.script = script
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(_ script: [Answer]) async throws -> StandIn {
        let server = try StandIn(script: script)
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: server.queue)
            server.read(connection, Data())
        }
        let ready = DispatchSemaphore(value: 0)
        server.listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        server.listener.start(queue: server.queue)
        _ = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: ready.wait(timeout: .now() + 5)) }
        }
        server.port = server.listener.port?.rawValue ?? 0
        return server
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, finished, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let body = Self.body(of: buffer) {
                answer(body, on: connection)
            } else if error != nil || finished {
                connection.cancel()
            } else {
                read(connection, buffer)
            }
        }
    }

    /// The body, once the headers and as many bytes as Content-Length says are in.
    private static func body(of buffer: Data) -> Data? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex ..< end.lowerBound], as: UTF8.self).lowercased()
        let length = head.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = buffer[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    private func answer(_ body: Data, on connection: NWConnection) {
        let answer: Answer = lock.withLock {
            bodies.append(body)
            return script.isEmpty ? Answer(status: 500, body: #"{"error":{"message":"script ran out"}}"#) : script.removeFirst()
        }
        let gone = Flag()
        if answer.hold > 0 {
            // Nothing more comes from a client that waits; the end of the
            // stream is it hanging up.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, finished, error in
                guard finished || error != nil else { return }
                gone.set()
                lock.withLock { hangUps.append(Date()) }
            }
        }
        let response = Data("HTTP/1.1 \(answer.status) Stand-in\r\nContent-Type: application/json\r\nContent-Length: \(answer.body.utf8.count)\r\nConnection: close\r\n\r\n\(answer.body)".utf8)
        queue.asyncAfter(deadline: .now() + answer.hold) { [self] in
            guard !gone.isSet else { return }
            lock.withLock { answered += 1 }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// How many samples the WAV in a transcription request carries.
private func samples(in body: Data) -> Int? {
    guard let riff = body.range(of: Data("RIFF".utf8)),
          let data = body.range(of: Data("data".utf8), in: riff.upperBound ..< body.endIndex),
          data.upperBound + 4 <= body.endIndex else { return nil }
    let size = body[data.upperBound ..< data.upperBound + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    return size / 2
}

// MARK: - A microphone that can be unplugged

/// A loud tone: speech, as far as SpeechGate can tell.
private func tone(seconds: Double) -> [Float] {
    (0 ..< Int(seconds * 16_000)).map {
        0.3 * sinf(Float($0) * 2 * .pi * 440 / 16_000) * (0.6 + 0.4 * sinf(Float($0) * 2 * .pi * 3 / 16_000))
    }
}

private final class UnpluggableMicrophone: AudioSource, @unchecked Sendable {
    var onLevel: (@Sendable @MainActor (Float) -> Void)?
    var onInputLost: (@Sendable @MainActor () -> Void)?
    private let lock = NSLock()
    private var heard: [Float] = []
    private var lost = false
    private var cancelled = false
    /// Gone already while it was being opened, before anyone listened.
    var unplugsWhileOpening = false

    var inputLost: Bool { lock.withLock { lost } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func start() async throws {
        if unplugsWhileOpening { unplug() }
    }

    var sampleCount: Int { lock.withLock { heard.count } }

    func samples(from start: Int, to end: Int) -> [Float] {
        lock.withLock {
            let upper = min(end, heard.count)
            guard start < upper else { return [] }
            return Array(heard[max(0, start) ..< upper])
        }
    }

    func finishSamples() async -> [Float]? {
        // A dead input has no tail to wait for, like AudioRecorder's.
        if !inputLost { try? await Task.sleep(for: .milliseconds(100)) }
        return lock.withLock { cancelled ? nil : heard }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            heard = []
        }
    }

    /// Someone speaks into it; into an unplugged one, nobody hears it.
    func speak(seconds: Double) {
        lock.withLock {
            guard !lost else { return }
            heard += tone(seconds: seconds)
        }
    }

    /// Unplugged, and nothing to fall back to: what AudioRecorder reports.
    func unplug() {
        lock.withLock { lost = true }
        guard let onInputLost else { return }
        Task { @MainActor in onInputLost() }
    }
}

// MARK: - A dictation

@MainActor
private final class Dictation {
    let preferences = Preferences(defaults: nil)
    let history = History()
    let session: Session
    var delivered: [String] = []
    var microphones: [UnpluggableMicrophone] = []
    var unplugsWhileOpening = false

    init(server: StandIn, mode: TriggerMode = .tap) {
        _ = NSApplication.shared
        // Never the real keys: the same stand-in folder and key the other
        // session tests use, so suites running side by side agree on it.
        Secrets.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("satz-core-tests-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent("keys", isDirectory: true)
        try? Secrets.store("test-key-not-real", for: .custom)
        preferences.provider = .custom
        preferences.customBaseURL = server.base
        preferences.model = "m"
        preferences.triggerMode = mode
        preferences.usesReplacements = false
        session = Session(preferences: preferences, history: history, discarded: Discarded())
        session.takesEscape = false
        session.deliverOverride = { [unowned self] text in delivered.append(text) }
        session.makeSource = { [unowned self] _ in
            let microphone = UnpluggableMicrophone()
            microphone.unplugsWhileOpening = unplugsWhileOpening
            microphones.append(microphone)
            return microphone
        }
    }

    var isLostAndPaused: Bool { session.phase == .paused && session.microphoneLost }
}

@MainActor
private func eventually(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite(.serialized) @MainActor
struct CodexR3RecordingTests {

    // MARK: I-2

    @Test func anUnpluggedMicrophonePausesKeepsTheWordsAndGoingOnOpensAFreshOne() async throws {
        let server = try await StandIn.start([
            .init(body: #"{"text":"Erster Teil"}"#),
            .init(body: #"{"text":"Erster Teil, zweiter Teil."}"#),
        ])
        defer { server.stop() }
        let d = Dictation(server: server)
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        let first = try #require(d.microphones.first)
        first.speak(seconds: 1)
        first.unplug()
        // Said into the dead microphone: it was never heard, and the card must not pretend.
        first.speak(seconds: 1)
        #expect(await eventually { d.isLostAndPaused }, "still \(d.session.phase) after the microphone was gone")
        // What it heard is written, not lost.
        #expect(await eventually(8) { d.session.plainText().contains("Erster Teil") })
        #expect(server.requests.count == 1 && samples(in: server.requests[0]) == 16_000)

        // Going on opens the input there is now, not the dead one.
        d.session.toggleMicrophone()
        #expect(await eventually { d.session.phase == .listening })
        try #require(d.microphones.count == 2)
        #expect(!d.session.microphoneLost)
        d.microphones[1].speak(seconds: 1)
        d.session.press()
        #expect(await eventually(8) { d.delivered == ["Erster Teil, zweiter Teil."] }, "\(d.session.phase), \(d.delivered)")
        // One recording at one spot, sent whole: before the loss and after.
        #expect(server.requests.count == 2 && samples(in: server.requests[1]) == 32_000)
        #expect(d.session.phase == .idle && !d.session.microphoneLost)
    }

    @Test func finishingAfterTheMicrophoneIsGoneSendsWhatWasRecorded() async throws {
        let server = try await StandIn.start([.init(body: #"{"text":"Nur der Anfang."}"#)])
        defer { server.stop() }
        let d = Dictation(server: server)
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try #require(d.microphones.count == 1)
        d.microphones[0].speak(seconds: 1)
        d.microphones[0].unplug()
        #expect(await eventually { d.isLostAndPaused })
        // Straight away, while its audio may still be on its way.
        d.session.press()
        #expect(await eventually(8) { d.delivered == ["Nur der Anfang."] }, "\(d.session.phase), \(d.delivered)")
        #expect(server.requests.count == 1 && samples(in: server.requests[0]) == 16_000)
        #expect(d.microphones.count == 1)
    }

    @Test func aMicrophoneGoneBeforeTheCardHeardItOpenStillPauses() async throws {
        let server = try await StandIn.start([])
        defer { server.stop() }
        let d = Dictation(server: server)
        d.unplugsWhileOpening = true
        d.session.press()
        #expect(await eventually { d.isLostAndPaused }, "\(d.session.phase)")
        #expect(server.requests.isEmpty)
        d.session.discard()
    }

    @Test func holdingTheKeyLettingGoAfterTheLossKeepsTheCardAndHoldingAgainGoesOn() async throws {
        let server = try await StandIn.start([
            .init(body: #"{"text":"Gehalten"}"#),
            .init(body: #"{"text":"Gehalten und weiter."}"#),
        ])
        defer { server.stop() }
        let d = Dictation(server: server, mode: .hold)
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try #require(d.microphones.count == 1)
        d.microphones[0].speak(seconds: 1)
        d.microphones[0].unplug()
        #expect(await eventually { d.isLostAndPaused })
        // Letting go sends nothing yet: the card says why it stopped listening.
        d.session.release()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(d.isLostAndPaused && d.delivered.isEmpty)
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try #require(d.microphones.count == 2)
        #expect(!d.session.microphoneLost)
        d.microphones[1].speak(seconds: 1)
        d.session.release()
        #expect(await eventually(8) { d.delivered == ["Gehalten und weiter."] }, "\(d.session.phase), \(d.delivered)")
    }

    @Test func aMicrophoneGoneInThePausesTailSaysSoAndKeepsTheWords() async throws {
        let server = try await StandIn.start([.init(body: #"{"text":"Vor der Pause."}"#)])
        defer { server.stop() }
        let d = Dictation(server: server)
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try #require(d.microphones.count == 1)
        d.microphones[0].speak(seconds: 1)
        d.session.toggleMicrophone()
        #expect(d.session.phase == .paused && !d.session.microphoneLost)
        // Gone while its tail still ran: the words come anyway, and the card
        // says why going on will use another input, as on Windows and Linux.
        d.microphones[0].unplug()
        #expect(await eventually { d.isLostAndPaused })
        #expect(await eventually(8) { d.session.plainText().contains("Vor der Pause.") })
        #expect(server.requests.count == 1 && samples(in: server.requests[0]) == 16_000)
        d.session.toggleMicrophone()
        #expect(await eventually { d.session.phase == .listening })
        #expect(d.microphones.count == 2 && !d.session.microphoneLost)
        d.session.discard()
    }

    @Test func aMicrophoneGoneAfterItsTailIsNoNews() async throws {
        let server = try await StandIn.start([.init(body: #"{"text":"Pause."}"#)])
        defer { server.stop() }
        let d = Dictation(server: server)
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try #require(d.microphones.count == 1)
        d.microphones[0].speak(seconds: 1)
        d.session.toggleMicrophone()
        #expect(await eventually(8) { d.session.plainText().contains("Pause.") })
        // Handed over and closed: what becomes of it later is not this dictation's.
        d.microphones[0].unplug()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(d.session.phase == .paused && !d.session.microphoneLost)
        d.session.discard()
    }

    // MARK: F07: a discard stops the cleanup request itself

    @Test func discardingWhileCleaningUpHangsUpOnTheModel() async throws {
        let server = try await StandIn.start([.init(body: #"{"choices":[{"message":{"content":"Hallo Welt, wie geht es dir?"},"finish_reason":"stop"}]}"#, hold: 4)])
        defer { server.stop() }
        let preferences = Preferences(defaults: nil)
        preferences.triggerMode = .tap
        preferences.cleansText = true
        preferences.cleanupProvider = .custom
        preferences.setCleanupAddress(server.base, for: .custom)
        preferences.setCleanupModel("stand-in", for: .custom)
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.readKey = { _ in "test-key-not-real" }
        let history = History()
        let session = Session(preferences: preferences, history: history, discarded: Discarded())
        session.takesEscape = false
        var delivered: [String] = []
        session.deliverOverride = { delivered.append($0) }
        session.cleaner = { text in await store.clean(text, preferences) }
        // Text on the card and nothing left to transcribe, as after Undo.
        let said = "hallo welt wie geht es dir"
        session.restore(Discarded.Snapshot(text: NSAttributedString(string: said), segments: [:], activeID: nil,
                                           nextID: 1, origin: nil, preview: said), keepingOrigin: true)
        session.press()
        #expect(await eventually { session.isCleaning && server.requests.count == 1 }, "\(session.phase), \(server.requests.count) requests")
        let discarded = Date()
        session.discard()
        #expect(session.phase == .discarded)
        // The request is called off, not left to run and be paid for.
        #expect(await eventually(2) { !server.hungUp.isEmpty }, "the cleanup request kept running after the discard")
        if let hungUp = server.hungUp.first { #expect(hungUp.timeIntervalSince(discarded) < 1.5) }
        // Past the moment the model would have answered: nothing arrives, nothing is measured.
        try? await Task.sleep(for: .seconds(3))
        #expect(server.answers == 0 && delivered.isEmpty && history.entries.isEmpty)
        #expect(store.speeds.count(.custom, model: "stand-in") == 0)
        session.discard()
    }

    // MARK: The card

    @Test func theCardSaysTheMicrophoneIsGoneInBothLanguages() throws {
        let language = Language.current
        defer { Language.current = language }
        let folder = ProcessInfo.processInfo.environment["SATZ_R3_CARDS"].map { URL(fileURLWithPath: $0) }
        for (name, spoken) in [("de", Language.german), ("en", .english)] {
            Language.current = spoken
            let preferences = Preferences(defaults: nil)
            for (kind, lost, text) in [("lost", true, ""), ("lost-text", true, "Bitte schick mir die Unterlagen."), ("paused", false, "")] {
                let session = Session(preferences: preferences, history: History(), discarded: Discarded())
                session.stage(.paused, text: text, microphoneLost: lost)
                #expect(session.microphoneLost == lost)
                let png = try SnapshotRenderer.png(of: CardView(session: session, preferences: preferences)
                    .environment(\.isSnapshot, true).frame(width: 460, height: 220))
                #expect(!png.isEmpty)
                try folder.map { try png.write(to: $0.appendingPathComponent("card-\(kind)-\(name).png")) }
            }
        }
    }
}
