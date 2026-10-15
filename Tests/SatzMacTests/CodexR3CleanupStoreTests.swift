import Foundation
import Testing
import SatzKit
@testable import SatzMac

// Third Codex audit (14.10.2026), the Mac cleanup store.
//
// MS3-01: a late answer to "what models do you have" overwrote the new
// address's list. MS3-02: the line under the switch promised the original in a
// history that keeps none. And a discarded dictation's cleanup: no more
// requests, no measurement. Nothing here reaches the network: the model list is
// answered by a closure the test holds back, the cleanup by a counting stub.

/// The model lists, answered when the test says so and in the order it says,
/// the way a slow server answers after a fast one.
private final class HeldAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Data, any Error>] = []
    private var paths: [String] = []

    /// The path of each ask, in the order they came.
    var asked: [String] { lock.withLock { paths } }

    func answer(_ base: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                paths.append(base.path)
                waiting.append(continuation)
            }
        }
    }

    /// The `index`th ask is answered with these models.
    func release(_ index: Int, models: [String]) {
        let list = models.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        lock.withLock { waiting[index] }.resume(returning: Data(#"{"data":[\#(list)]}"#.utf8))
    }

    /// The `index`th ask fails, as a server that is not running does.
    func fail(_ index: Int) {
        lock.withLock { waiting[index] }.resume(throwing: URLError(.cannotConnectToHost))
    }
}

/// Counts every cleanup request and answers it, so a request that should not
/// have been sent shows.
private final class CountingStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = [] } }
    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.seen.append(request) }
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"Hallo Welt, wie geht es dir?"}}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Try-state tests run beside the cancellation suite. Their successful
/// requests must not enter that suite's strict "nothing sent" counter.
private final class TryAnswerStub: URLProtocol, @unchecked Sendable {
    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TryAnswerStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"Hallo Welt, wie geht es dir?"}}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Opened by the test, awaited by the stand-in for Apple's model. A plain
/// wait, so it does not notice a cancellation: the answer comes anyway.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    private var entered = false

    var isEntered: Bool { lock.withLock { entered } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                entered = true
                if open { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            open = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

@MainActor
private func until(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Not `Task.sleep`: this holds the actor, which is the point of its one use.
private func blockThisActor(for seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

private let oldAddress = "http://127.0.0.1:11434/old/v1"
private let newAddress = "http://127.0.0.1:11434/new/v1"

// MARK: - MS3-01: the model list belongs to the address

@Suite(.serialized) @MainActor
struct CodexR3ModelListTests {

    /// Codex's case: the address is changed while the old server is still
    /// thinking, the new server answers first, the old one later.
    @Test func aLateAnswerOfTheOldAddressDoesNotReplaceTheNewOnesModels() async {
        let held = HeldAnswers()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { try await held.answer($0) }
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .ollama

        preferences.setCleanupAddress(oldAddress, for: .ollama)
        let old = Task { await store.refreshInstalled(.ollama, address: oldAddress) }
        await until { held.asked.count == 1 }
        preferences.setCleanupAddress(newAddress, for: .ollama)
        let new = Task { await store.refreshInstalled(.ollama, address: newAddress) }
        await until { held.asked.count == 2 }

        held.release(1, models: ["new-only-model"])
        await new.value
        #expect(store.modelID(.ollama, preferences) == "new-only-model")
        held.release(0, models: ["old-only-model"])
        await old.value

        // The next dictation asks the new server for the model it has.
        let job = store.job(.ollama, preferences)
        #expect(job.baseURL?.path == "/new/v1" && job.model.id == "new-only-model")
        #expect(store.models(.ollama, address: newAddress).map(\.id) == ["new-only-model"])
        // The old server's answer is nobody's now.
        #expect(store.installedModels(.ollama, address: oldAddress) == nil)
    }

    /// The same, with the old server failing late: the healthy new list stays
    /// and the new server is not called "not running".
    @Test func aLateFailureOfTheOldAddressDoesNotClearTheNewOnesModels() async {
        let held = HeldAnswers()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { try await held.answer($0) }
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .ollama

        let old = Task { await store.refreshInstalled(.ollama, address: oldAddress) }
        await until { held.asked.count == 1 }
        preferences.setCleanupAddress(newAddress, for: .ollama)
        let new = Task { await store.refreshInstalled(.ollama, address: newAddress) }
        await until { held.asked.count == 2 }

        held.release(1, models: ["new-only-model"])
        await new.value
        held.fail(0)
        await old.value

        #expect(store.installedModels(.ollama, address: newAddress) == ["new-only-model"])
        #expect(!store.isNotRunning(.ollama, address: newAddress) && !store.isNotRunning(.ollama, address: oldAddress))
        #expect(store.modelID(.ollama, preferences) == "new-only-model")
    }

    /// The same address asked twice: the answer that arrives last is not
    /// always the newest. The ask made later wins.
    @Test func anOlderAnswerOfTheSameAddressDoesNotReplaceANewerOne() async {
        let held = HeldAnswers()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { try await held.answer($0) }

        let first = Task { await store.refreshInstalled(.ollama, address: newAddress) }
        await until { held.asked.count == 1 }
        let second = Task { await store.refreshInstalled(.ollama, address: newAddress) }
        await until { held.asked.count == 2 }

        held.release(1, models: ["pulled-just-now"])
        await second.value
        held.release(0, models: ["before-the-pull"])
        await first.value
        #expect(store.installedModels(.ollama, address: newAddress) == ["pulled-just-now"])
    }

    /// Settings and a dictation both ask the same server; whichever answers
    /// first serves both, and the other one does not undo it.
    @Test func twoAsksForTheSameServerBothEndWithItsAnswer() async {
        let held = HeldAnswers()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { try await held.answer($0) }
        let settings = Task { await store.refreshInstalled(.ollama, address: newAddress) }
        await until { held.asked.count == 1 }
        let dictation = Task { await store.refreshInstalled(.ollama, address: newAddress) }
        await until { held.asked.count == 2 }
        held.release(0, models: ["gemma4:4b"])
        await settings.value
        #expect(store.installedModels(.ollama, address: newAddress) == ["gemma4:4b"])
        held.release(1, models: ["gemma4:4b"])
        await dictation.value
        #expect(store.installedModels(.ollama, address: newAddress) == ["gemma4:4b"])
    }

    /// An address that cannot be used has no list, and the answer of the
    /// address typed before it does not become one.
    @Test func anAddressThatCannotBeUsedHasNoModels() async {
        let held = HeldAnswers()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { try await held.answer($0) }
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .ollama
        preferences.setCleanupAddress(oldAddress, for: .ollama)
        let old = Task { await store.refreshInstalled(.ollama, address: oldAddress) }
        await until { held.asked.count == 1 }
        // Typed on: not an address (https or the own network only).
        preferences.setCleanupAddress("ftp://server", for: .ollama)
        await store.refreshInstalled(.ollama, address: "ftp://server")
        held.release(0, models: ["old-only-model"])
        await old.value
        #expect(held.asked.count == 1)
        #expect(store.modelID(.ollama, preferences).isEmpty)
        #expect(store.models(.ollama, address: "ftp://server").isEmpty && !store.isNotRunning(.ollama, address: "ftp://server"))
    }

    @Test func aServerThatDoesNotAnswerIsNotRunningAtThatAddressOnly() async {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { base in
            if base.path == "/new/v1" { return Data(#"{"data":[{"id":"new-only-model"}]}"#.utf8) }
            throw URLError(.cannotConnectToHost)
        }
        await store.refreshInstalled(.ollama, address: oldAddress)
        #expect(store.isNotRunning(.ollama, address: oldAddress) && store.installedModels(.ollama, address: oldAddress) == nil)
        // Asked again at another address, which answers: the old verdict goes with the old address.
        await store.refreshInstalled(.ollama, address: newAddress)
        #expect(!store.isNotRunning(.ollama, address: newAddress) && !store.isNotRunning(.ollama, address: oldAddress))
        #expect(store.installedModels(.ollama, address: newAddress) == ["new-only-model"])
        // And back: it asks again, and says not running again.
        await store.refreshInstalled(.ollama, address: oldAddress)
        #expect(store.isNotRunning(.ollama, address: oldAddress) && store.installedModels(.ollama, address: newAddress) == nil)
    }

    /// LM Studio and Ollama do not share a list, even at one address.
    @Test func eachProviderHasItsOwnList() async {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { _ in Data(#"{"data":[{"id":"shared-looking"}]}"#.utf8) }
        await store.refreshInstalled(.ollama, address: newAddress)
        #expect(store.installedModels(.ollama, address: newAddress) == ["shared-looking"])
        #expect(store.installedModels(.lmStudio, address: newAddress) == nil)
        // A provider without a list never asks.
        await store.refreshInstalled(.openAI, address: "https://api.openai.com/v1")
        #expect(store.models(.openAI).count == CleanupCatalog.models(for: .openAI).count)
    }

    /// The address as typed varies; the server is one.
    @Test func theSameServerTypedTwoWaysIsOneList() async {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { _ in Data(#"{"data":[{"id":"gemma4:4b"}]}"#.utf8) }
        await store.refreshInstalled(.ollama, address: "http://LOCALHOST:11434/v1/")
        for typed in ["", "http://localhost:11434/v1", "  http://localhost:11434/v1  "] {
            #expect(store.installedModels(.ollama, address: typed) == ["gemma4:4b"], "'\(typed)'")
        }
        #expect(store.installedModels(.ollama, address: "http://localhost:11435/v1") == nil)
    }

    /// Settings stops the ask of the address it no longer shows; that is not
    /// the server being down.
    @Test func anAskThatWasStoppedSaysNothingAboutTheServer() async {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { _ in
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
        let task = Task { await store.refreshInstalled(.ollama, address: oldAddress) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(!store.isNotRunning(.ollama, address: oldAddress) && store.installedModels(.ollama, address: oldAddress) == nil)
    }

    @Test func aFixtureStagesTheListAtTheProvidersOwnAddress() {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.stage(installed: [.ollama: ["gemma4:4b", "qwen3.8:8b"]])
        let preferences = Preferences(defaults: nil)
        #expect(store.models(.ollama).map(\.id) == ["gemma4:4b", "qwen3.8:8b"])
        #expect(store.modelID(.ollama, preferences) == "gemma4:4b")
        // At another address the staged list is not the server's.
        preferences.setCleanupAddress(newAddress, for: .ollama)
        #expect(store.modelID(.ollama, preferences).isEmpty)
        #expect(store.missing(.ollama, preferences, hasKey: { _ in false }) == [.model])
    }
}

// MARK: - A discarded dictation

@Suite(.serialized) @MainActor
struct CodexR3DiscardedCleanupTests {

    private let said = "hallo welt wie geht es dir"

    @Test func aCleanupDiscardedWhileAskingForTheModelsSendsNothing() async {
        let held = HeldAnswers()
        CountingStub.reset()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.fetchModels = { try await held.answer($0) }
        store.client = CleanupClient(session: CountingStub.session)
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .ollama

        let run = Task { await store.clean(said, preferences) }
        await until { held.asked.count == 1 }
        run.cancel()
        // The server answers all the same.
        held.release(0, models: ["gemma4:4b"])
        let result = await run.value
        #expect(result.text == said && result.cleaned == nil && result.seconds == nil)
        #expect(result.failure == .notReachable && result.detail == "cancelled")
        #expect(CountingStub.requests.isEmpty)
    }

    @Test func aCleanupDiscardedBeforeItStartsSendsNothing() async {
        CountingStub.reset()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.client = CleanupClient(session: CountingStub.session)
        store.readKey = { _ in "test-key-not-real" }
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .openAI
        let run = Task {
            while !Task.isCancelled { await Task.yield() }
            return await store.clean(said, preferences)
        }
        run.cancel()
        let result = await run.value
        #expect(result.detail == "cancelled" && CountingStub.requests.isEmpty)
    }

    /// The model answered after the dictation was discarded: that time says
    /// how long the discarded work took, not how fast the model is.
    @Test func aCleanupDiscardedWhileItRanIsNotMeasured() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-r3-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cleanup-speeds.json")
        let gate = Gate()
        let store = CleanupStore(folder: nil, speedsFile: file)
        // Apple's path, stood in for: the real model is never needed here.
        store.client = CleanupClient(apple: { _ in
            await gate.wait()
            return "Hallo Welt, wie geht es dir?"
        })
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .apple

        let run = Task { await store.clean(said, preferences) }
        await until { gate.isEntered }
        run.cancel()
        gate.release()
        let result = await run.value
        #expect(result.detail == "cancelled" && result.text == said)
        #expect(store.speeds.count(.apple, model: "apple") == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // The control: the same run, not discarded, is measured and kept.
        let again = CleanupStore(folder: nil, speedsFile: file)
        again.client = CleanupClient(apple: { _ in "Hallo Welt, wie geht es dir?" })
        let kept = await again.clean(said, preferences)
        #expect(kept.failure == nil && again.speeds.count(.apple, model: "apple") == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The answer is in before the dictation is discarded, and the store has
    /// not looked at it yet (this actor is busy): its time is not a
    /// measurement either, and the answer is not logged.
    @Test func anAnswerThatAlreadyArrivedIsNotMeasuredEitherOnceTheCleanupIsDiscarded() async {
        let gate = Gate()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.client = CleanupClient(apple: { _ in
            await gate.wait()
            return "Hallo Welt, wie geht es dir?"
        })
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .apple
        let run = Task { await store.clean(said, preferences) }
        await until { gate.isEntered }
        gate.release()
        // Blocks this actor, so the client finishes and cannot hand over yet.
        blockThisActor(for: 0.3)
        run.cancel()
        let result = await run.value
        #expect(result.detail == "cancelled" && result.text == said)
        #expect(store.speeds.count(.apple, model: "apple") == 0)
    }

    /// "Ausprobieren" stopped by a second click: nothing is measured either
    /// (this held before; kept so the two paths stay the same).
    @Test func aTryThatWasStoppedIsNotMeasured() async {
        let gate = Gate()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.client = CleanupClient(apple: { _ in
            await gate.wait()
            return "Hallo Welt, wie geht es dir?"
        })
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .apple
        store.tryOut(said, preferences)
        await until { gate.isEntered }
        store.tryOut(said, preferences)
        gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!store.trying && store.tried == nil && store.speeds.count(.apple, model: "apple") == 0)
    }
}

@Suite(.serialized) @MainActor
struct CleanupTryInputTests {
    @Test func aLateTryAnswerDoesNotAppearUnderAnotherProvider() async {
        let gate = Gate()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.client = CleanupClient(apple: { _ in
            await gate.wait()
            return "Hallo Welt, wie geht es dir?"
        })
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .apple
        store.tryOut("hallo welt wie geht es dir", preferences)
        await until { gate.isEntered }
        store.looking = .ollama
        gate.release()
        await until { !store.trying }
        #expect(store.tried == nil)
        #expect(store.speeds.count(.apple, model: "apple") == 0)
    }

    @Test func changesToTheShownSettingsOrSampleRemoveACompletedTry() async {
        let said = "hallo welt wie geht es dir"
        let changes: [(CleanupStore, Preferences) -> String] = [
            { store, _ in store.looking = .ollama; return said },
            { _, preferences in preferences.setCleanupModel("second", for: .custom); return said },
            { _, preferences in preferences.setCleanupAddress("http://127.0.0.1:10/v1", for: .custom); return said },
            { _, preferences in preferences.chooseCleanupLevel(.polished); return said },
            { _, preferences in preferences.cleanupPrompt = "Add punctuation."; return said },
            { _, preferences in preferences.words = ["Syntheticword"]; return said },
            { _, _ in "another synthetic sample" },
        ]
        for change in changes {
            let store = CleanupStore(folder: nil, speedsFile: nil)
            store.client = CleanupClient(session: TryAnswerStub.session)
            let preferences = Preferences(defaults: nil)
            preferences.cleanupProvider = .custom
            preferences.setCleanupAddress("http://127.0.0.1:9/v1", for: .custom)
            preferences.setCleanupModel("stand-in", for: .custom)
            preferences.chooseCleanupLevel(.custom)
            preferences.cleanupPrompt = "Keep every word."
            store.tryOut(said, preferences)
            await until { !store.trying }
            #expect(store.tried != nil)
            // The same transition CleanupTryBox delivers through onChange.
            store.discardStaleTry(change(store, preferences), preferences)
            #expect(store.tried == nil && !store.trying)
        }
    }

    @Test func invalidatingAPendingTryDoesNotLetItsLateAnswerReplaceANewTry() async {
        let gate = Gate()
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.client = CleanupClient(apple: { _ in await gate.wait(); return "Hallo Welt, wie geht es dir?" })
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .apple
        let said = "hallo welt wie geht es dir"
        store.tryOut(said, preferences)
        await until { gate.isEntered }
        preferences.chooseCleanupLevel(.polished)
        store.discardStaleTry(said, preferences)
        #expect(!store.trying && store.tried == nil)
        store.client = CleanupClient(apple: { _ in "Hallo Welt, wie geht es dir?" })
        store.tryOut(said, preferences)
        await until { !store.trying }
        let fresh = store.tried
        #expect(fresh?.result.failure == nil && fresh != nil)
        gate.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.tried == fresh && store.speeds.count(.apple, model: "apple") == 1)
    }

    @Test func aPriceOrDiscoveryUpdateDoesNotInvalidateTheSameInput() async {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.client = CleanupClient(session: TryAnswerStub.session)
        store.stage(installed: [.ollama: ["before"]])
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .ollama
        store.tryOut("hallo welt wie geht es dir", preferences)
        await until { !store.trying }
        let kept = store.tried
        #expect(kept != nil)
        store.fetchModels = { _ in Data(#"{"data":[{"id":"after"}]}"#.utf8) }
        await store.refreshInstalled(.ollama, address: "")
        preferences.cleanupPrompt = "Unused at the light level."
        store.discardStaleTry("hallo welt wie geht es dir", preferences)
        #expect(store.tried == kept && !store.trying)
    }
}

// MARK: - MS3-02: the line under the switch

@Suite(.serialized) @MainActor
struct CodexR3HistoryOffWordingTests {

    private func lines(_ history: History) -> (de: String, en: String) {
        let language = Language.current
        defer { Language.current = language }
        Language.current = .german
        let german = CleanupBlock.switchLine(for: history)
        Language.current = .english
        return (german, CleanupBlock.switchLine(for: history))
    }

    @Test func withAHistoryTheOriginalStaysThere() {
        for history in [History(limit: 10), History(limit: History.standardLimit), History()] {
            let (german, english) = lines(history)
            #expect(german == "Ein Sprachmodell überarbeitet den Text, bevor satz ihn einfügt. Das Original bleibt im Verlauf.")
            #expect(english == "A language model edits the text before satz pastes it. The original stays in the history.")
        }
    }

    @Test func withTheHistoryOffTheLineSaysTheOriginalIsNotKept() {
        let (german, english) = lines(History(limit: 0))
        #expect(german == "Ein Sprachmodell überarbeitet den Text, bevor satz ihn einfügt. Der Verlauf ist aus: das Original wird nicht aufbewahrt.")
        #expect(english == "A language model edits the text before satz pastes it. History is off: the original is not kept.")
        #expect(!german.contains("bleibt im Verlauf") && !english.contains("stays in the history"))
        #expect(!german.contains("\u{2014}") && !english.contains("\u{2014}"))
    }

    /// The history is switched off in Settings while the window is open: the
    /// line follows, because it reads the history itself.
    @Test func theLineFollowsTheHistoryWhenItIsSwitchedOff() {
        let history = History(limit: 50)
        #expect(lines(history).en.contains("stays in the history"))
        history.limit = 0
        #expect(lines(history).en.contains("History is off"))
        history.limit = 10
        #expect(lines(history).en.contains("stays in the history"))
    }
}
