import AppKit
import Foundation
import Testing
import SatzKit
@testable import SatzMac

// Tests for the Mac core: the clipboard, the keyboard's place, the music, the
// card's spot and the session. Needs the test target SatzMacTests (see
// Package.swift); none of it touches the real clipboard, music, keys or
// windows: private pasteboards, fakes, a temporary key folder and a scripted
// provider.

// MARK: - Clipboard

private func board() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("plus.dpa.satz.tests.\(UUID().uuidString)"))
}

private func string(_ board: NSPasteboard) -> String? { board.string(forType: .string) }

private func copyByUser(_ text: String, to board: NSPasteboard) {
    board.clearContents()
    board.setString(text, forType: .string)
}

@Suite(.serialized) @MainActor
struct ClipboardTests {

    @Test func aPasteGivesBackWhatWasCopiedBefore() {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        _ = Paster.put("transcript-1", on: board)
        #expect(string(board) == "transcript-1")
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "original-A")
    }

    @Test func twoPastesInARowGiveBackTheClipboardFromBeforeBoth() {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        _ = Paster.put("transcript-1", on: board)
        _ = Paster.put("transcript-2", on: board)
        Paster.restorePendingNow(on: board)
        // Not "transcript-1", which is what the second paste found on the clipboard.
        #expect(string(board) == "original-A")
    }

    @Test func somethingCopiedBetweenTwoPastesIsNotOverwrittenByTheOlderClipboard() {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        _ = Paster.put("transcript-1", on: board)
        // The user copies something new before the first clipboard is back.
        copyByUser("newly-copied-B", to: board)
        _ = Paster.put("transcript-2", on: board)
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "newly-copied-B")
    }

    @Test func somethingCopiedAfterThePasteStaysToo() {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        _ = Paster.put("transcript-1", on: board)
        copyByUser("newer", to: board)
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "newer")
    }

    @Test func anEmptyClipboardIsEmptyAgain() {
        let board = board(); defer { board.releaseGlobally() }
        board.clearContents()

        _ = Paster.put("geheimer Diktattext", on: board)
        #expect(string(board) == "geheimer Diktattext")
        Paster.restorePendingNow(on: board)
        #expect(string(board) == nil)
        #expect((board.pasteboardItems ?? []).isEmpty)
    }

    @Test func anEmptyClipboardIsNotClearedOverSomethingCopiedMeanwhile() {
        let board = board(); defer { board.releaseGlobally() }
        board.clearContents()

        _ = Paster.put("transcript", on: board)
        copyByUser("newer", to: board)
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "newer")
    }

    @Test func theClipboardComesBackAfterTheWait() async {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        let ours = Paster.put("transcript-1", on: board)
        Paster.handBackSoon(ours, on: board, after: .milliseconds(80))
        #expect(string(board) == "transcript-1")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(string(board) == "original-A")
        // Nothing left to give back.
        copyByUser("later", to: board)
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "later")
    }

    @Test func quittingGivesTheClipboardBackAtOnceAndTheTimerDoesNothingLater() async {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        let ours = Paster.put("transcript-1", on: board)
        Paster.handBackSoon(ours, on: board, after: .milliseconds(150))
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "original-A")
        // The cancelled timer must not run over what the user copies next.
        copyByUser("next", to: board)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(string(board) == "next")
    }

    @Test func theTimerOfTheFirstPasteDoesNotGiveTheClipboardBackUnderTheSecond() async {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        let first = Paster.put("transcript-1", on: board)
        Paster.handBackSoon(first, on: board, after: .milliseconds(100))
        // The second paste is on its way (its ⌘V not sent yet) when the first timer would fire.
        _ = Paster.put("transcript-2", on: board)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(string(board) == "transcript-2")
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "original-A")
    }

    @Test func aPendingPasteIsInheritedUntilItIsGivenBack() {
        let board = board(); defer { board.releaseGlobally() }
        copyByUser("original-A", to: board)

        let ours = Paster.put("transcript-1", on: board)
        Paster.handBackSoon(ours, on: board, after: .seconds(30))
        // Pending until it is given back: a second paste inherits it.
        _ = Paster.put("transcript-2", on: board)
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "original-A")
        // Nothing pending any more.
        copyByUser("now", to: board)
        Paster.restorePendingNow(on: board)
        #expect(string(board) == "now")
    }
}

// MARK: - The keyboard's place

/// Two windows and two fields of one app, with calls recorded.
@MainActor
private final class FakeKeyboard: KeyboardPlace {
    // Real elements only as identities: they compare by process.
    static let windowA = AXUIElementCreateApplication(1)
    static let windowB = AXUIElementCreateApplication(2)
    static let fieldA = AXUIElementCreateApplication(3)
    static let fieldB = AXUIElementCreateApplication(4)

    var focusedWindow: AXUIElement?
    var focusedField: AXUIElement?
    var windowsThatExist: [AXUIElement] = [windowA, windowB]
    var calls: [String] = []

    init(window: AXUIElement?, field: AXUIElement?) {
        focusedWindow = window
        focusedField = field
    }

    func exists(_ window: AXUIElement) -> Bool { windowsThatExist.contains { CFEqual($0, window) } }

    func bringForward(_ window: AXUIElement) {
        calls.append("bringForward")
        focusedWindow = window
    }

    func focus(_ field: AXUIElement) {
        calls.append("focus")
        focusedField = field
    }
}

@MainActor
struct KeyboardPlaceTests {
    fileprivate typealias K = FakeKeyboard

    @Test func theFieldIsBroughtBackEvenWhenTheWindowIsTheSame() {
        // Dictated in field A; while the text was on its way the user clicked into field B.
        let keyboard = FakeKeyboard(window: K.windowA, field: K.fieldB)
        #expect(Paster.bringBack(window: K.windowA, field: K.fieldA, in: keyboard))
        #expect(keyboard.calls == ["focus"])
        #expect(CFEqual(keyboard.focusedField, K.fieldA))
    }

    @Test func nothingIsMovedWhereTheKeyboardAlreadyIs() {
        let keyboard = FakeKeyboard(window: K.windowA, field: K.fieldA)
        #expect(Paster.bringBack(window: K.windowA, field: K.fieldA, in: keyboard))
        #expect(keyboard.calls.isEmpty)
    }

    @Test func anotherWindowComesForwardAndThenItsField() {
        let keyboard = FakeKeyboard(window: K.windowB, field: K.fieldB)
        #expect(Paster.bringBack(window: K.windowA, field: K.fieldA, in: keyboard))
        #expect(keyboard.calls == ["bringForward", "focus"])
    }

    @Test func aWindowThatIsGoneIsReportedAndNothingIsFocused() {
        let keyboard = FakeKeyboard(window: K.windowB, field: K.fieldB)
        keyboard.windowsThatExist = [K.windowB]
        #expect(!Paster.bringBack(window: K.windowA, field: K.fieldA, in: keyboard))
        #expect(keyboard.calls.isEmpty)
    }

    @Test func aWindowWithoutAFieldOnlyComesForward() {
        let keyboard = FakeKeyboard(window: K.windowB, field: K.fieldB)
        #expect(Paster.bringBack(window: K.windowA, field: nil, in: keyboard))
        #expect(keyboard.calls == ["bringForward"])
    }

    @Test func anAppThatDoesNotSayWhereItsKeyboardIsIsLeftAlone() {
        let silent = FakeKeyboard(window: nil, field: nil)
        #expect(Paster.bringBack(window: K.windowA, field: K.fieldA, in: silent))
        #expect(silent.calls.isEmpty)
        let started = FakeKeyboard(window: K.windowB, field: K.fieldB)
        #expect(Paster.bringBack(window: nil, field: nil, in: started))
        #expect(started.calls.isEmpty)
    }
}

// MARK: - Music

/// The system's players: one is current, and Pause and Play go to it.
private final class FakePlayers: @unchecked Sendable {
    private let lock = NSLock()
    private var state: NowPlaying.State?
    private var log: [String] = []

    init(playing pid: Int32) { state = NowPlaying.State(playing: true, pid: pid) }

    var commands: [String] { lock.withLock { log } }

    func read() -> NowPlaying.State? { lock.withLock { state } }

    /// Whoever is current changes, or stops being readable.
    func become(_ new: NowPlaying.State?) { lock.withLock { state = new } }

    func send(_ command: MediaCommand) {
        lock.withLock {
            log.append(command == .play ? "play" : "pause")
            if let state { self.state = NowPlaying.State(playing: command == .play, pid: state.pid) }
        }
    }
}

@MainActor
private func media(_ players: FakePlayers) -> MediaPause {
    let media = MediaPause()
    media.nowPlaying = { players.read() }
    media.send = { players.send($0) }
    return media
}

@MainActor
private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    return condition()
}

@Suite(.serialized) @MainActor
struct MediaPauseTests {

    @Test func whatSatzPausedPlaysAgain() async {
        let players = FakePlayers(playing: 100)
        let media = media(players)
        media.dictationStarted()
        #expect(await eventually { players.commands == ["pause"] })
        media.dictationEnded()
        #expect(await eventually { players.commands == ["pause", "play"] })
    }

    @Test func aDifferentPlayerThatBecameCurrentIsNotStarted() async {
        let players = FakePlayers(playing: 100)
        let media = media(players)
        media.dictationStarted()
        #expect(await eventually { players.commands == ["pause"] })
        // The user makes another, paused, player the system's current one meanwhile.
        players.become(NowPlaying.State(playing: false, pid: 200))
        media.dictationEnded()
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(players.commands == ["pause"])
    }

    @Test func somethingTheUserStartedMeanwhileIsLeftAlone() async {
        let players = FakePlayers(playing: 100)
        let media = media(players)
        media.dictationStarted()
        #expect(await eventually { players.commands == ["pause"] })
        // The user presses play on the same player themselves.
        players.become(NowPlaying.State(playing: true, pid: 100))
        media.dictationEnded()
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(players.commands == ["pause"])
    }

    @Test func notKnowingWhatIsCurrentIsNoReasonToPlay() async {
        let players = FakePlayers(playing: 100)
        let media = media(players)
        media.dictationStarted()
        #expect(await eventually { players.commands == ["pause"] })
        players.become(nil)
        media.dictationEnded()
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(players.commands == ["pause"])
    }

    @Test func nothingPlayingMeansNothingIsPaused() async {
        let players = FakePlayers(playing: 100)
        players.become(NowPlaying.State(playing: false, pid: 100))
        let media = media(players)
        media.dictationStarted()
        media.dictationEnded()
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(players.commands.isEmpty)
    }

    @Test func quittingPlaysWhatSatzPausedAndOnlyThat() async {
        let same = FakePlayers(playing: 100)
        let one = media(same)
        one.dictationStarted()
        #expect(await eventually { same.commands == ["pause"] })
        one.quitting()
        #expect(same.commands == ["pause", "play"])

        let other = FakePlayers(playing: 100)
        let two = media(other)
        two.dictationStarted()
        #expect(await eventually { other.commands == ["pause"] })
        other.become(NowPlaying.State(playing: false, pid: 200))
        two.quitting()
        #expect(other.commands == ["pause"])
    }
}

// MARK: - The card's spot

@Suite(.serialized) @MainActor
struct CardSpotTests {

    @Test func aCardLetGoOfAfterAPauseKeepsItsSpot() async {
        let panel = CardPanel()   // never shown
        var saves = 0
        panel.onMoved = { saves += 1 }
        panel.mouseIsDown = { true }

        panel.setFrameOrigin(NSPoint(x: 120, y: 160))
        // Held still for longer than the wait for the moves to stop.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(saves == 0)

        panel.mouseIsDown = { false }
        panel.dropped()
        #expect(saves == 1)
        // Once: the timer that was waiting must not save it again.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(saves == 1)
    }

    @Test func aCardLetGoOfRightAwayIsSavedOnce() async {
        let panel = CardPanel()
        var saves = 0
        panel.onMoved = { saves += 1 }
        panel.mouseIsDown = { true }

        panel.setFrameOrigin(NSPoint(x: 60, y: 80))
        try? await Task.sleep(for: .milliseconds(50))
        panel.mouseIsDown = { false }
        panel.dropped()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(saves == 1)
    }

    @Test func theDragEndingInTheCardsViewSavesTheSpot() async {
        let preferences = Preferences(defaults: nil)
        let controller = CardController(session: Session(preferences: preferences, history: History(), discarded: Discarded()),
                                        preferences: preferences)
        let panel = CardPanel()
        controller.panel = panel
        var saves = 0
        panel.onMoved = { saves += 1 }
        panel.mouseIsDown = { true }

        controller.drag(true)
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + 40, y: panel.frame.origin.y + 20))
        try? await Task.sleep(for: .milliseconds(500))
        #expect(saves == 0)
        panel.mouseIsDown = { false }
        controller.drag(false)
        #expect(saves == 1)
        // A second end without a drag in between saves nothing.
        controller.drag(false)
        #expect(saves == 1)
    }

    @Test func aClickThatMovedNothingSavesNothing() async {
        let panel = CardPanel()
        var saves = 0
        panel.onMoved = { saves += 1 }
        panel.dropped()
        #expect(saves == 0)
    }

    @Test func theCardPlacedBySatzIsNotTheUsersChoice() async {
        let panel = CardPanel()
        var saves = 0
        panel.onMoved = { saves += 1 }
        panel.place(offset: nil, avoiding: nil)
        try? await Task.sleep(for: .milliseconds(450))
        panel.dropped()
        #expect(saves == 0)
    }
}

// MARK: - The session

/// A provider that answers from a script, for the shared session of URLs.
private final class SessionStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [(delay: TimeInterval, status: Int, body: String)] = []
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var registered = false
    private let lock = NSLock()
    private var cancelled = false

    /// "mac-mini.local" stands for a model server on the home network: the
    /// stub answers it, so no test ever sends anything to a real address.
    override class func canInit(with request: URLRequest) -> Bool { ["provider.test", "mac-mini.local"].contains(request.url?.host) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let next = Self.script.isEmpty ? (delay: 0, status: 200, body: #"{"text":"Wort"}"#) : Self.script.removeFirst()
        DispatchQueue.global().asyncAfter(deadline: .now() + next.delay) { [self] in
            guard !lock.withLock({ cancelled }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(next.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { lock.withLock { cancelled = true } }

    static func reset(_ script: [(TimeInterval, Int, String)]) {
        if !registered {
            URLProtocol.registerClass(SessionStub.self)
            registered = true
        }
        self.script = script.map { (delay: $0.0, status: $0.1, body: $0.2) }
        requests = 0
    }
}

private let audioFolder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-core-tests-\(ProcessInfo.processInfo.processIdentifier)")

/// A 16 kHz mono clip: a loud tone (speech, as far as SpeechGate can tell) or silence.
private func clip(_ name: String, seconds: Double, tone: Bool = true) -> URL {
    try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
    let samples: [Float] = (0 ..< Int(seconds * 16_000)).map {
        tone ? 0.3 * sinf(Float($0) * 2 * .pi * 440 / 16_000) * (0.6 + 0.4 * sinf(Float($0) * 2 * .pi * 3 / 16_000)) : 0
    }
    let url = audioFolder.appendingPathComponent(name + ".wav")
    try? WAVEncoder.encode(samples: samples, sampleRate: 16_000).write(to: url)
    return url
}

@MainActor
private final class Dictation {
    let preferences = Preferences(defaults: nil)
    let history = History()
    let discarded = Discarded()
    let session: Session
    var delivered: [String] = []

    /// - Parameter clips: what the microphone plays, one per recording.
    init(clips: [URL], mode: TriggerMode = .tap, model: String = "m", address: String = "https://provider.test/v1",
         script: [(TimeInterval, Int, String)] = []) {
        _ = NSApplication.shared
        // Never the real keys.
        Secrets.directory = audioFolder.appendingPathComponent("keys", isDirectory: true)
        try? Secrets.store("test-key-not-real", for: .custom)
        SessionStub.reset(script)
        preferences.provider = .custom
        preferences.customBaseURL = address
        preferences.model = model
        preferences.triggerMode = mode
        preferences.usesReplacements = false
        AudioSources.testFiles = clips
        session = Session(preferences: preferences, history: history, discarded: discarded)
        session.takesEscape = false
        session.deliverOverride = { [unowned self] text in delivered.append(text) }
    }

    var isFailed: Bool { if case .failed = session.phase { true } else { false } }
    var failureCanRetry: Bool? { if case .failed(_, let canRetry) = session.phase { canRetry } else { nil } }

    /// Starts, talks for a second, and presses again.
    func dictate(for seconds: Double = 1) async {
        session.press()
        _ = await eventually { self.session.phase == .listening }
        try? await Task.sleep(for: .seconds(seconds))
        session.press()
    }
}

@Suite(.serialized) @MainActor
struct SessionTests {

    @Test func silenceIsNotUploaded() async {
        let d = Dictation(clips: [clip("silence", seconds: 2, tone: false)], script: [(0, 200, #"{"text":"Vielen Dank."}"#)])
        await d.dictate()
        #expect(await eventually(8) { d.session.phase == .idle || d.isFailed })
        #expect(SessionStub.requests == 0)
        #expect(d.delivered.isEmpty)
        // "Nichts gehört", without a Retry that would hear the same.
        #expect(d.failureCanRetry == false)
    }

    @Test func speechIsUploadedAndDelivered() async {
        let d = Dictation(clips: [clip("speech", seconds: 2)], script: [(0, 200, #"{"text":"Hallo Welt."}"#)])
        await d.dictate()
        #expect(await eventually(8) { !d.delivered.isEmpty })
        #expect(SessionStub.requests == 1)
        #expect(d.delivered == ["Hallo Welt."])
    }

    @Test func holdingTheKeyAgainWhileTheLastOneIsWrittenStartsTheNextRecording() async {
        let d = Dictation(clips: [clip("h1", seconds: 3), clip("h2", seconds: 3)], mode: .hold,
                          script: [(1.2, 200, #"{"text":"Eins"}"#), (0, 200, #"{"text":"Zwei"}"#)])
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try? await Task.sleep(for: .milliseconds(800))
        d.session.release()
        #expect(await eventually { d.session.phase == .finishing })
        // The key goes down again while "Schreibt" shows.
        d.session.press()
        #expect(d.session.phase == .finishing)
        #expect(await eventually(8) { d.delivered == ["Eins"] })
        // The next recording begins as soon as the first is out, the key still held.
        #expect(await eventually { d.session.phase == .starting || d.session.phase == .listening })
        try? await Task.sleep(for: .milliseconds(800))
        d.session.release()
        #expect(await eventually(8) { d.delivered == ["Eins", "Zwei"] })
    }

    @Test func aKeyLetGoBeforeTheLastOneIsOutStartsNothing() async {
        let d = Dictation(clips: [clip("r1", seconds: 3), clip("r2", seconds: 3)], mode: .hold,
                          script: [(1.0, 200, #"{"text":"Eins"}"#)])
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try? await Task.sleep(for: .milliseconds(800))
        d.session.release()
        #expect(await eventually { d.session.phase == .finishing })
        d.session.press()
        d.session.release()
        #expect(await eventually(8) { d.delivered == ["Eins"] })
        // No recording with nobody holding the key: it would run until the next press.
        try? await Task.sleep(for: .milliseconds(800))
        #expect(d.session.phase == .idle)
    }

    @Test func aCustomEndpointWithoutAModelDoesNotStartRecording() async {
        let d = Dictation(clips: [clip("m1", seconds: 2)], model: "  ")
        d.session.press()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(d.isFailed)
        #expect(d.failureCanRetry == false)
        // The microphone was never asked for: its recording is still waiting.
        #expect(AudioSources.testFiles?.count == 1)
        #expect(SessionStub.requests == 0)
    }

    @Test func aCustomEndpointWithoutAnAddressDoesNotStartRecording() async {
        let d = Dictation(clips: [clip("a1", seconds: 2)], address: "")
        d.session.press()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(d.isFailed)
        #expect(AudioSources.testFiles?.count == 1)
    }

    @Test func aRecordingTheProviderRefusesAsTooLargeOffersNoRetry() async {
        let d = Dictation(clips: [clip("t1", seconds: 2)], script: [(0, 413, #"{"error":{"message":"File too large"}}"#)])
        await d.dictate()
        #expect(await eventually(8) { d.isFailed })
        #expect(d.failureCanRetry == false)
        // The retry button's action does nothing either.
        d.session.retry()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(SessionStub.requests == 1)
    }

    @Test func undoAfterTheCrossGoesBackToTheWindowAndFieldTheDictationStartedIn() async {
        let d = Dictation(clips: [clip("u1", seconds: 3)], script: [(0, 200, #"{"text":"Wieder da."}"#)])
        let window = AXUIElementCreateApplication(11), field = AXUIElementCreateApplication(12)
        d.session.captureFocus = { _ in (window, field) }
        d.session.press()
        #expect(await eventually { d.session.phase == .listening })
        try? await Task.sleep(for: .milliseconds(800))
        d.session.discard()
        #expect(d.session.phase == .discarded)

        d.session.undoDiscard()
        #expect(d.session.phase == .paused)
        // Without them the paste went to whichever window of the app was in front by then.
        #expect(d.session.originWindow.map { CFEqual($0, window) } == true)
        #expect(d.session.originField.map { CFEqual($0, field) } == true)
        // Undo sends what was on its way again; let that answer arrive before the
        // next test sets up its own script.
        #expect(await eventually { d.session.inFlight.isEmpty && SessionStub.requests > 0 })
        d.session.discard()
    }

    @Test func aRedirectThatWasNotFollowedShowsAddressRedirectsOnTheCard() async {
        // What a refused redirect comes back as (`Transcriber.StaysOnOrigin`):
        // the 3xx answer. The card reads "Provider error (307)" in no language.
        let d = Dictation(clips: [clip("redirect1", seconds: 2)], script: [(0, 307, "")])
        await d.dictate()
        #expect(await eventually(8) { d.isFailed })
        guard case .failed(let reason, let canRetry) = d.session.phase else { Issue.record("\(d.session.phase)"); return }
        #expect(["Adresse leitet um", "Address redirects"].contains(reason), "\(reason)")
        // Once the address is changed, asking again works.
        #expect(canRetry)
    }

    @Test(arguments: [("", ["Adresse fehlt", "Address missing"]), ("http://example.com/v1", ["Adresse geht nicht", "Address won't work"]),
                      ("ftp://nas/v1", ["Adresse geht nicht", "Address won't work"])])
    func anAddressThatIsTypedButRefusedIsNotCalledMissingOnTheCard(address: String, words: [String]) async {
        let d = Dictation(clips: [clip("address2", seconds: 2)], address: address)
        d.session.press()
        #expect(await eventually(8) { d.isFailed })
        guard case .failed(let reason, _) = d.session.phase else { Issue.record("\(d.session.phase)"); return }
        #expect(words.contains(reason), "\(reason)")
        // The microphone was never asked for, and nothing was sent.
        #expect(SessionStub.requests == 0)
    }

    @Test func aModelServerOnTheHomeNetworkIsAcceptedAndRecordingStarts() async {
        // Plain http to a name on the home network used to be refused as "address missing".
        let d = Dictation(clips: [clip("home1", seconds: 2)], address: "http://mac-mini.local:11434/v1",
                          script: [(0, 200, #"{"text":"Zuhause."}"#)])
        await d.dictate()
        #expect(await eventually(8) { !d.delivered.isEmpty }, "\(d.session.phase) after \(SessionStub.requests) requests")
        #expect(d.delivered == ["Zuhause."])
        #expect(SessionStub.requests == 1)
    }

    @Test func aFailureThatMayPassStillOffersRetry() async {
        let d = Dictation(clips: [clip("t2", seconds: 2)], script: [(0, 500, #"{"error":{"message":"boom"}}"#)])
        await d.dictate()
        #expect(await eventually(8) { d.isFailed })
        #expect(d.failureCanRetry == true)
    }
}

// MARK: - Cleanup in the session

/// A cleanup that answers from a script and counts what it was given.
@MainActor
private final class FakeCleaner {
    var given: [String] = []
    var delay: Duration = .zero
    var answer: (String) -> CleanupResult

    init(_ answer: @escaping (String) -> CleanupResult) { self.answer = answer }

    func attach(to d: Dictation) {
        d.session.cleaner = { [self] text in
            given.append(text)
            if delay > .zero { try? await Task.sleep(for: delay) }
            return answer(text)
        }
    }
}

extension SessionTests {

    @Test func anInterruptedDeliveryKeepsAudioAndRetriesWithoutTranscribingAgain() async {
        let d = Dictation(clips: [clip("delivery-interrupted", seconds: 2)],
                          script: [(0, 200, #"{"text":"Synthetic retained words."}"#)])
        d.history.limit = 0
        d.session.deliverOverride = nil
        var attempts = 0
        d.session.pasteText = { _, _, _, _, _, _ in
            attempts += 1
            return attempts == 1 ? .notPasted("Synthetic clipboard change") : .pasted
        }
        await d.dictate()
        #expect(await eventually(8) { d.isFailed })
        #expect(d.session.plainText() == "Synthetic retained words.")
        #expect(SessionStub.requests == 1)
        d.session.discard()
        #expect(d.discarded.last?.segments.values.contains { !$0.audio.isEmpty } == true)
        d.session.undoDiscard()
        d.session.press()
        #expect(await eventually(8) { attempts == 2 && d.session.phase == .idle })
        #expect(SessionStub.requests == 1)
        #expect(d.history.entries.isEmpty)
    }

    @Test func cleanupOnPastesTheCleanedTextAndTheHistoryKeepsTheOriginal() async {
        let d = Dictation(clips: [clip("c1", seconds: 2)], script: [(0, 200, #"{"text":"hallo welt wie geht es dir"}"#)])
        d.preferences.cleansText = true
        let cleaner = FakeCleaner { _ in CleanupResult(text: "Hallo Welt, wie geht es dir?", cleaned: "Hallo Welt, wie geht es dir?", seconds: 0.2) }
        cleaner.attach(to: d)
        await d.dictate()
        #expect(await eventually(8) { !d.delivered.isEmpty })
        #expect(d.delivered == ["Hallo Welt, wie geht es dir?"])
        // Exactly what would have been pasted otherwise.
        #expect(cleaner.given == ["hallo welt wie geht es dir"])
        #expect(d.history.entries.first?.text == "Hallo Welt, wie geht es dir?")
        #expect(d.history.entries.first?.original == "hallo welt wie geht es dir")
        #expect(d.history.entries.first?.cleanup == "ok")
        #expect(d.session.lastCleanup?.outcome == "ok" && d.session.phase == .idle)
    }

    @Test func aFailedCleanupPastesTheOriginalWithTheReasonAndANotice() async {
        for failure in [CleanupFailure.tooSlow, .rejected, .providerError] {
            let d = Dictation(clips: [clip("f-\(failure.code)", seconds: 2)], script: [(0, 200, #"{"text":"hallo welt wie geht es dir"}"#)])
            d.preferences.cleansText = true
            FakeCleaner { text in CleanupResult(text: text, failure: failure, seconds: 0.3) }.attach(to: d)
            await d.dictate()
            #expect(await eventually(8) { !d.delivered.isEmpty })
            #expect(d.delivered == ["hallo welt wie geht es dir"])
            #expect(d.history.entries.first?.original == nil)
            #expect(d.history.entries.first?.cleanup == failure.short())
            #expect(d.session.lastCleanup?.failure == failure)
            // "Nicht aufgeräumt" for a moment, then the card goes.
            #expect(d.session.phase == .notCleaned)
            #expect(await eventually(5) { d.session.phase == .idle })
        }
    }

    @Test func whileCleaningTheCardSaysSoAndADiscardDropsTheLateAnswer() async {
        let d = Dictation(clips: [clip("d1", seconds: 2)], script: [(0, 200, #"{"text":"hallo welt wie geht es dir"}"#)])
        d.preferences.cleansText = true
        let cleaner = FakeCleaner { _ in CleanupResult(text: "Zu spät.", cleaned: "Zu spät.", seconds: 1.5) }
        cleaner.delay = .milliseconds(1500)
        cleaner.attach(to: d)
        await d.dictate()
        #expect(await eventually(8) { d.session.isCleaning })
        #expect(d.session.phase == .finishing)
        d.session.discard()
        #expect(d.session.phase == .discarded && !d.session.isCleaning)
        try? await Task.sleep(for: .milliseconds(1800))
        #expect(d.delivered.isEmpty && d.history.entries.isEmpty)
        // What was said can still come back.
        d.session.undoDiscard()
        #expect(d.session.plainText().contains("hallo welt"))
        d.session.discard()
    }

    @Test func cleanupOffChangesNothingAndAsksNobody() async {
        let d = Dictation(clips: [clip("o0", seconds: 2), clip("o1", seconds: 2)],
                          script: [(0, 200, #"{"text":"erst aufgeräumt"}"#), (0, 200, #"{"text":"hallo welt"}"#)])
        let cleaner = FakeCleaner { _ in CleanupResult(text: "Anders.", cleaned: "Anders.") }
        cleaner.attach(to: d)
        // One with cleanup first: test mode's dump must not show it for the next.
        d.preferences.cleansText = true
        await d.dictate()
        #expect(await eventually(8) { d.delivered.count == 1 && d.session.phase == .idle })
        #expect(d.session.lastCleanup?.outcome == "ok")
        d.preferences.cleansText = false
        await d.dictate()
        #expect(await eventually(8) { d.delivered.count == 2 })
        #expect(d.delivered.last == "hallo welt" && cleaner.given == ["erst aufgeräumt"])
        #expect(d.history.entries.first?.cleanup == nil && d.history.entries.first?.original == nil)
        #expect(d.session.lastCleanup == nil)
        #expect(d.session.phase == .idle)
    }
}
