import Foundation
import Testing
import SatzKit
@testable import SatzMac

// The cleanup's preferences, its history fields and its store, in memory or
// in temporary files: never the user's preferences, history or keys. The
// session's part is in CoreFixMacTests (SessionTests), which shares the
// microphone stand-in.

@MainActor
private func isolated(_ body: (UserDefaults) -> Void) {
    let name = "plus.dpa.satz.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    let language = Language.current, theme = AppTheme.current
    defer {
        defaults.removePersistentDomain(forName: name)
        Language.current = language
        AppTheme.current = theme
    }
    body(defaults)
}

@Suite(.serialized) @MainActor
struct CleanupPreferencesTests {

    @Test func offByDefaultAtLight() {
        let preferences = Preferences(defaults: nil)
        #expect(!preferences.cleansText)
        #expect(preferences.cleanupLevel == .light && preferences.cleanupPrompt.isEmpty)
        #expect(preferences.cleanupProviderChoice == nil)
    }

    @Test func untilOneIsPickedCleanupGoesWhereTranscriptionDoes() {
        let preferences = Preferences(defaults: nil)
        preferences.provider = .groq
        #expect(preferences.cleanupProvider == .groq)
        preferences.provider = .google
        #expect(preferences.cleanupProvider == .google)
        // Microsoft does not clean up; a fixture has no OpenRouter key and no Apple.
        preferences.provider = .microsoft
        #expect(preferences.cleanupProvider == .openRouter)
        preferences.cleanupProvider = .anthropic
        preferences.provider = .groq
        #expect(preferences.cleanupProvider == .anthropic)
    }

    @Test func theOwnPromptStartsWithTheLevelChosenBefore() {
        let preferences = Preferences(defaults: nil)
        preferences.chooseCleanupLevel(.smooth)
        preferences.chooseCleanupLevel(.custom)
        #expect(preferences.cleanupPrompt == CleanupLevel.smooth.instructions)
        // Once written, it stays the user's.
        preferences.cleanupPrompt = "Translate it into English."
        preferences.chooseCleanupLevel(.light)
        preferences.chooseCleanupLevel(.custom)
        #expect(preferences.cleanupPrompt == "Translate it into English.")
    }

    @Test func everythingIsKeptBetweenRuns() {
        isolated { defaults in
            let first = Preferences(defaults: defaults)
            first.cleansText = true
            first.chooseCleanupLevel(.polished)
            first.cleanupProvider = .ollama
            first.setCleanupModel("gemma4:4b", for: .ollama)
            first.setCleanupAddress("http://127.0.0.1:11434/v1", for: .ollama)
            first.cleanupPrompt = "Mach es kurz."
            let again = Preferences(defaults: defaults)
            #expect(again.cleansText && again.cleanupLevel == .polished && again.cleanupProvider == .ollama)
            #expect(again.cleanupModel(for: .ollama) == "gemma4:4b")
            #expect(again.cleanupAddress(for: .ollama) == "http://127.0.0.1:11434/v1")
            #expect(again.cleanupPrompt == "Mach es kurz.")
        }
    }

    @Test func eachProviderHasItsOwnModelAndAddress() {
        let preferences = Preferences(defaults: nil)
        #expect(preferences.cleanupModel(for: .openRouter) == "google/gemini-3.5-flash-lite")
        #expect(preferences.cleanupModel(for: .anthropic) == "claude-haiku-5-5")
        #expect(preferences.cleanupModel(for: .cerebras) == "qwen-3.8-27b")
        #expect(preferences.cleanupModel(for: .google) == "gemini-3.5-flash-lite")
        #expect(preferences.cleanupModel(for: .mistral) == "mistral-small-latest")
        #expect(preferences.cleanupModel(for: .xai) == "grok-4.7")
        #expect(preferences.cleanupModel(for: .ollama).isEmpty && preferences.cleanupModel(for: .custom).isEmpty)
        #expect(preferences.cleanupAddress(for: .ollama) == "http://localhost:11434/v1")
        #expect(preferences.cleanupAddress(for: .lmStudio) == "http://localhost:1234/v1")
        #expect(preferences.cleanupAddress(for: .custom).isEmpty)
        preferences.setCleanupModel("anthropic/claude-haiku-5.5", for: .openRouter)
        #expect(preferences.cleanupModel(for: .openRouter) == "anthropic/claude-haiku-5.5")
        #expect(preferences.cleanupModel(for: .openAI) == "gpt-6-luna")
    }
}

@Suite(.serialized) @MainActor
struct CleanupHistoryTests {

    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-cleanup-history-\(UUID().uuidString)")

    @Test func anOldHistoryFileStillLoads() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.json")
        try Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"Alt.","date":780000000,"app":"Mail","pasted":true}]"#.utf8).write(to: file)
        let history = History(file: file)
        #expect(history.entries.count == 1)
        #expect(history.entries.first?.text == "Alt." && history.entries.first?.original == nil && history.entries.first?.cleanup == nil)
    }

    @Test func theOriginalIsKeptOnlyWhenItDiffers() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.json")
        let history = History(file: file)
        history.add("Hallo Welt.", app: nil, pasted: true, original: "hallo welt", cleanup: "ok")
        history.add("Schon sauber.", app: nil, pasted: true, original: "Schon sauber.", cleanup: "ok")
        history.add("zu langsam hier", app: nil, pasted: true, cleanup: "Zu langsam")
        let again = History(file: file)
        #expect(again.entries.map(\.original) == [nil, nil, "hallo welt"])
        #expect(again.entries.map(\.cleanup) == ["Zu langsam", "ok", "ok"])
        // The estimate counts what was said.
        #expect(again.spokenLengths == ["zu langsam hier".count, "Schon sauber.".count, "hallo welt".count])
    }

    /// As Unicode scalars, the way Windows and Linux count (`[...text].length`):
    /// an emoji family is five of them, a letter and its accent two.
    @Test func lengthsAreCountedAsUnicodeScalars() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let history = History(file: folder.appendingPathComponent("history.json"))
        history.add("e\u{301}", app: nil, pasted: true)
        history.add("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ok", app: nil, pasted: true)
        history.add("Aufgeräumt.", app: nil, pasted: true, original: "ähm aufgeräumt", cleanup: "ok")
        #expect(history.spokenLengths == ["ähm aufgeräumt".unicodeScalars.count, 5 + 3, 2])
    }
}

/// Answers every request itself, so nothing here reaches the network, and
/// counts them.
private final class AnsweringStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = [] } }
    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnsweringStub.self]
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

@Suite(.serialized) @MainActor
struct CleanupStoreTests {

    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-cleanup-store-\(UUID().uuidString)")

    @Test func ollamaUsesItsFirstModelUntilOneIsPicked() {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.stage(installed: [.ollama: ["gemma4:4b", "qwen3.8:8b"]])
        let preferences = Preferences(defaults: nil)
        let job = store.job(.ollama, preferences)
        #expect(job.model.id == "gemma4:4b" && job.key == nil)
        #expect(job.baseURL?.absoluteString == "http://localhost:11434/v1")
        #expect(job.model.isFree && job.model.extras["reasoning_effort"] == .string("none"))
        preferences.setCleanupModel("qwen3.8:8b", for: .ollama)
        #expect(store.job(.ollama, preferences).model.id == "qwen3.8:8b")
        #expect(store.models(.ollama).map(\.id) == ["gemma4:4b", "qwen3.8:8b"])
    }

    @Test func theJobCarriesTheLevelThePromptAndTheWordsButNoPhrases() {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        let preferences = Preferences(defaults: nil)
        preferences.words = ["Jannik", "ACON"]
        preferences.chooseCleanupLevel(.custom)
        preferences.cleanupPrompt = "Kürzer."
        let job = store.job(.lmStudio, preferences)
        #expect(job.level == .custom && job.customPrompt == "Kürzer." && job.vocabulary == ["Jannik", "ACON"])
    }

    @Test func whatIsMissingUsesSetupsKeys() {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.stage(apple: .notEnabled)
        let preferences = Preferences(defaults: nil)
        #expect(store.missing(.openRouter, preferences, hasKey: { _ in false }) == [.key])
        #expect(store.missing(.openRouter, preferences, hasKey: { _ in true }).isEmpty)
        #expect(store.missing(.custom, preferences, hasKey: { _ in false }) == [.address, .model])
        #expect(store.missing(.apple, preferences, hasKey: { _ in false }) == [.apple(.notEnabled)])
        // Ollama's address is there by default; its model once it answers.
        #expect(store.missing(.ollama, preferences, hasKey: { _ in false }) == [.model])
    }

    @Test func eachCleanupIsMeasuredAndKeptOnDisk() async throws {
        let file = folder.appendingPathComponent("cleanup-speeds.json")
        let store = CleanupStore(folder: nil, speedsFile: file)
        // Apple's path, stood in for: the real model is never needed here.
        store.client = CleanupClient(apple: { _ in "Hallo Welt, wie geht es dir?" })
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .apple
        let first = await store.clean("hallo welt wie geht es dir", preferences)
        #expect(first.failure == nil && first.text == "Hallo Welt, wie geht es dir?")
        _ = await store.clean("hallo welt wie geht es dir", preferences)
        #expect(store.speeds.count(.apple, model: "apple") == 2)
        #expect(store.speeds.seconds(.apple, model: "apple") != nil)
        let again = CleanupStore(folder: nil, speedsFile: file)
        #expect(again.speeds.count(.apple, model: "apple") == 2)
        // A failed request says nothing about the model's speed.
        store.client = CleanupClient(apple: { _ in throw CleanupFailure.providerError })
        _ = await store.clean("hallo welt wie geht es dir", preferences)
        #expect(store.speeds.count(.apple, model: "apple") == 2)
    }

    @Test func tryingUsesTheProviderShownAndASecondClickStopsIt() async {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        store.client = CleanupClient(apple: { _ in
            try await Task.sleep(for: .milliseconds(300))
            return "Also, ich wollte fragen, ob wir das Meeting am Dienstag machen können."
        })
        let preferences = Preferences(defaults: nil)
        preferences.provider = .openRouter
        store.looking = .apple
        var done = false
        store.tryOut("ähm also ich wollte fragen ob wir das meeting am montag nein am dienstag machen können", preferences) { done = true }
        #expect(store.trying)
        for _ in 0 ..< 40 where !done { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(done && !store.trying)
        #expect(store.tried?.provider == .apple && store.tried?.result.failure == nil)
        // Again, and again before it is back: stopped, nothing new.
        store.tryOut("noch einmal bitte", preferences)
        store.tryOut("noch einmal bitte", preferences)
        #expect(!store.trying && store.tried == nil)
    }

    // MARK: Test mode

    /// A test copy shares the key files with the real satz: cleanup there goes
    /// only to this computer, else `cleanup:on` would spend the user's money.
    @Test func inTestModeCleanupGoesOnlyToThisComputer() async {
        AnsweringStub.reset()
        let store = CleanupStore(folder: nil, speedsFile: nil, onlyThisComputer: true)
        store.client = CleanupClient(session: AnsweringStub.session)
        store.readKey = { _ in "test-key-not-real" }
        let preferences = Preferences(defaults: nil)
        let said = "hallo welt wie geht es dir"
        for provider in [CleanupProvider.openRouter, .openAI, .anthropic, .google, .groq, .xai] {
            preferences.cleanupProvider = provider
            #expect(store.job(provider, preferences).onlyThisComputer)
            let result = await store.clean(said, preferences)
            #expect(result.failure == .notReachable && result.text == said, "\(provider)")
            #expect(result.detail?.hasPrefix("test mode sends nothing to \(provider.rawValue)") == true)
        }
        #expect(AnsweringStub.requests.isEmpty)
        // "Ausprobieren" for a provider that is only shown: the same.
        store.looking = .openRouter
        var done = false
        store.tryOut(said, preferences) { done = true }
        for _ in 0 ..< 40 where !done { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(done && store.tried?.result.failure == .notReachable && store.tried?.provider == .openRouter)
        #expect(AnsweringStub.requests.isEmpty)
        // An address on this computer still works.
        preferences.cleanupProvider = .custom
        preferences.setCleanupAddress("http://127.0.0.1:9/v1", for: .custom)
        preferences.setCleanupModel("stand-in", for: .custom)
        let here = await store.clean(said, preferences)
        #expect(here.failure == nil && here.text == "Hallo Welt, wie geht es dir?" && AnsweringStub.requests.count == 1)
        // The user's own satz is not in test mode.
        #expect(!CleanupStore(folder: nil, speedsFile: nil).job(.openRouter, preferences).onlyThisComputer)
    }

    @Test func theTestCopyAllowsRemoteOnlyWhenTheTestSaysSo() async {
        AnsweringStub.reset()
        let store = CleanupStore(folder: nil, speedsFile: nil, onlyThisComputer: false)
        store.client = CleanupClient(session: AnsweringStub.session)
        store.readKey = { _ in "test-key-not-real" }
        let preferences = Preferences(defaults: nil)
        preferences.cleanupProvider = .openRouter
        let result = await store.clean("hallo welt wie geht es dir", preferences)
        #expect(result.failure == nil && AnsweringStub.requests.first?.url?.host == "openrouter.ai")
    }

    // MARK: OpenRouter's list

    private func list(_ id: String) -> Data {
        Data(#"{"data":[{"id":"\#(id)","pricing":{"prompt":"0.0000003","completion":"0.0000025"}}]}"#.utf8)
    }

    /// After a failure the list is not asked for again within ten minutes,
    /// however often Settings is opened; Windows and Linux wait the same.
    @Test func aFailedPriceListIsNotAskedAgainForTenMinutes() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = CleanupStore(folder: folder, speedsFile: nil)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var asked = 0
        var fail = true
        store.now = { clock }
        store.fetchPrices = { [self] in
            asked += 1
            if fail { throw URLError(.notConnectedToInternet) }
            return list("google/gemini-3.5-flash-lite")
        }
        await store.refreshPrices()?.value
        #expect(asked == 1 && store.listings.isEmpty)
        // Settings opened again and again: nothing is asked.
        for minutes in [0.1, 1, 5, 9.9] {
            clock = Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60)
            #expect(store.refreshPrices() == nil)
        }
        #expect(asked == 1)
        // Ten minutes after the failure it asks again, and a second failure waits again.
        clock = Date(timeIntervalSince1970: 1_800_000_000 + 10 * 60)
        await store.refreshPrices()?.value
        #expect(asked == 2)
        clock = Date(timeIntervalSince1970: 1_800_000_000 + 19 * 60)
        #expect(store.refreshPrices() == nil)
        // It works again: the list is kept, and for a day nothing is asked.
        fail = false
        clock = Date(timeIntervalSince1970: 1_800_000_000 + 21 * 60)
        await store.refreshPrices()?.value
        #expect(asked == 3 && store.listings.count == 1)
        clock = Date(timeIntervalSince1970: 1_800_000_000 + 21 * 60 + 23 * 3600)
        #expect(store.refreshPrices() == nil && asked == 3)
        // A day later, again.
        clock = Date(timeIntervalSince1970: 1_800_000_000 + 21 * 60 + 25 * 3600)
        await store.refreshPrices()?.value
        #expect(asked == 4)
    }

    /// A list that is there but lacks the model has no facts about its
    /// thinking either: off, not the catalog's value; with no list, the catalog's.
    @Test func theJobKnowsWhetherAListIsKept() {
        let store = CleanupStore(folder: nil, speedsFile: nil)
        let preferences = Preferences(defaults: nil)
        preferences.setCleanupModel("z-ai/glm-5.3", for: .openRouter)
        let without = store.job(.openRouter, preferences)
        #expect(!without.listKept && without.listing == nil)
        #expect(CleanupRequest.make(without, text: "hallo")!.1["reasoning"] == .object(["effort": .string("low")]))
        store.stageListings(["google/gemini-3.5-flash-lite": OpenRouterListing(id: "google/gemini-3.5-flash-lite", input: 0.3, output: 2.5)])
        let lacking = store.job(.openRouter, preferences)
        #expect(lacking.listKept && lacking.listing == nil)
        #expect(CleanupRequest.make(lacking, text: "hallo")!.1["reasoning"] == .object(["enabled": .bool(false)]))
        // Other providers have no such list.
        #expect(!store.job(.openAI, preferences).listKept)
    }
}

// MARK: - The state file

/// What test mode's `dump` writes about cleanup: the same keys, the same
/// values, as the test mode of Windows and Linux.
@Suite(.serialized) @MainActor
struct CleanupStateFileTests {

    private func keys(_ state: [String: Any]) -> Set<String> { Set(state.keys) }

    @Test func aCleanedDictationIsOkWithoutAReason() {
        let record = Session.CleanupRecord(outcome: "ok", failure: nil, original: "hallo welt", cleaned: "Hallo Welt.",
                                           provider: "custom", model: "stand-in", seconds: 0.31)
        let state = DevControl.cleanupState(record)
        #expect(keys(state) == ["outcome", "original", "cleaned", "provider", "model", "seconds"])
        #expect(state["outcome"] as? String == "ok" && state["cleaned"] as? String == "Hallo Welt." && state["original"] as? String == "hallo welt")
        #expect(state["provider"] as? String == "custom" && state["model"] as? String == "stand-in" && state["seconds"] as? Double == 0.31)
    }

    @Test func aFailureHasItsStableCodeAndTheShortReason() {
        let language = Language.current
        defer { Language.current = language }
        Language.current = .german
        // The guard threw the answer out: it is still in `cleaned`.
        let rejected = DevControl.cleanupState(Session.CleanupRecord(outcome: CleanupFailure.rejected.code, failure: .rejected, original: "was ist die hauptstadt",
                                                                     cleaned: "Canberra.", provider: "openrouter", model: "m", seconds: 0.9))
        #expect(rejected["outcome"] as? String == "rejected" && rejected["reason"] as? String == "Antwort verworfen" && rejected["cleaned"] as? String == "Canberra.")
        // Nothing came back: null, not the pasted original.
        let slow = DevControl.cleanupState(Session.CleanupRecord(outcome: CleanupFailure.tooSlow.code, failure: .tooSlow, original: "hallo",
                                                                 cleaned: nil, provider: "openrouter", model: "m", seconds: 6.0))
        #expect(slow["outcome"] as? String == "too-slow" && slow["reason"] as? String == "Zu langsam" && slow["cleaned"] is NSNull)
        #expect(keys(slow) == ["outcome", "reason", "original", "cleaned", "provider", "model", "seconds"])
        // The stable codes are the same strings on every platform.
        let codes: [(CleanupFailure, String)] = [
            (.noKey, "no-key"), (.keyRejected, "key-rejected"), (.noCredit, "no-credit"), (.modelNotFound, "model-not-found"),
            (.tooManyRequests, "too-many-requests"), (.refused(422), "refused-422"), (.providerError, "provider-error"),
            (.notReachable, "not-reachable"), (.tooSlow, "too-slow"), (.rejected, "rejected"), (.empty, "empty"), (.cutOff, "cut-off"),
            (.answerRefused, "answer-refused"), (.noAddress, "no-address"), (.noModel, "no-model"), (.noPrompt, "no-prompt"),
        ]
        for (failure, code) in codes { #expect(failure.code == code) }
    }

    @Test func aTryHasTheKeysOfACleanupAndWhetherTheGuardRejectedIt() {
        let language = Language.current
        defer { Language.current = language }
        Language.current = .english
        let ok = CleanupStore.Tried(provider: .custom, model: "stand-in", result: CleanupResult(text: "Hallo.", cleaned: "Hallo.", seconds: 0.4, dollars: 0.0001))
        let okState = DevControl.tryState(ok)
        #expect(keys(okState) == ["provider", "model", "outcome", "cleaned", "rejected", "seconds", "dollars"])
        #expect(okState["outcome"] as? String == "ok" && okState["rejected"] as? Bool == false && okState["cleaned"] as? String == "Hallo.")
        #expect(okState["dollars"] as? Double == 0.0001 && okState["seconds"] as? Double == 0.4)

        let rejected = CleanupStore.Tried(provider: .openRouter, model: "m", result: CleanupResult(text: "frage", failure: .rejected, cleaned: "Antwort", seconds: 0.5))
        let rejectedState = DevControl.tryState(rejected)
        #expect(keys(rejectedState) == ["provider", "model", "outcome", "cleaned", "rejected", "reason", "seconds", "dollars"])
        #expect(rejectedState["outcome"] as? String == "rejected" && rejectedState["rejected"] as? Bool == true)
        #expect(rejectedState["reason"] as? String == "Answer rejected" && rejectedState["cleaned"] as? String == "Antwort" && rejectedState["dollars"] is NSNull)

        let slow = CleanupStore.Tried(provider: .openRouter, model: "m", result: CleanupResult(text: "frage", failure: .notReachable))
        let slowState = DevControl.tryState(slow)
        #expect(slowState["outcome"] as? String == "not-reachable" && slowState["reason"] as? String == "Not reachable" && slowState["rejected"] as? Bool == false)
        #expect(slowState["cleaned"] is NSNull && slowState["seconds"] is NSNull)
    }
}
