import Foundation
import Observation
import SatzKit

/// Everything around cleaning up the text that is not a preference: what
/// OpenRouter charges now, which models Ollama and LM Studio have, how fast
/// each model was on this computer, and the "Ausprobieren" box.
@MainActor
@Observable
final class CleanupStore {

    /// OpenRouter's live list, by model id.
    private(set) var listings: [String: OpenRouterListing] = [:]
    /// What the servers of Ollama and LM Studio answered when asked what they
    /// have installed or loaded. By provider and address, so an answer only
    /// ever speaks for the server it came from.
    private var discovered: [Server: Discovery] = [:]
    private(set) var speeds = CleanupSpeeds()
    private(set) var appleState: AppleCleanup.State = .unsupported
    /// The provider Settings shows while it is not the one in use: clicking
    /// one in the menu only shows it, "… benutzen" switches.
    var looking: CleanupProvider?

    /// "Ausprobieren": running, and what came of the last one.
    private(set) var trying = false
    private(set) var tried: Tried?

    struct Tried: Equatable {
        let provider: CleanupProvider
        let model: String
        let result: CleanupResult
    }

    /// One server: the provider and its address as `CleanupAddress.url`
    /// reduces it ("localhost:11434/v1/" and "http://localhost:11434/v1" are
    /// the same one). nil for a provider that has no list, or an address
    /// that cannot be used.
    struct Server: Hashable {
        let provider: CleanupProvider
        let address: String

        init?(_ provider: CleanupProvider, address typed: String) {
            guard provider == .ollama || provider == .lmStudio,
                  let url = CleanupAddress.url(provider.address(typed)) else { return nil }
            self.provider = provider
            address = url.absoluteString
        }
    }

    private enum Discovery: Equatable {
        case models([String])
        /// Asked, and nobody answered: the server is not running.
        case silent
    }

    @ObservationIgnored private var tryTask: Task<Void, Never>?
    /// The server each provider was asked last. An answer counts only while
    /// its server is that one, and only if no later answer of the same server
    /// is in already: Settings asks again for every address typed, and the
    /// answer of the one before may come after (`refreshInstalled`).
    @ObservationIgnored private var lastAsked: [CleanupProvider: Server] = [:]
    @ObservationIgnored private var asks = 0
    /// The ask whose answer a server's entry holds.
    @ObservationIgnored private var answeredAt: [Server: Int] = [:]
    @ObservationIgnored private var fetchingPrices = false
    /// When the last fetch of OpenRouter's list failed: not tried again for
    /// ten minutes, so a Settings window opened and closed does not ask each time.
    @ObservationIgnored private var pricesFailed: Date?
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let speedsFile: URL?
    /// Test mode: cleanup goes only to this computer (`LaunchMode.cleanupStaysHere`).
    @ObservationIgnored private let onlyThisComputer: Bool
    /// Replaced by tests, which talk to a stand-in server.
    @ObservationIgnored var client = CleanupClient()
    /// The key of an account; replaced by tests, which never read the user's.
    @ObservationIgnored var readKey: (String) -> String? = { Secrets.read(account: $0) }
    /// OpenRouter's list, as the bytes it answered; replaced by tests.
    @ObservationIgnored var fetchPrices: () async throws -> Data = {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: CleanupCatalog.openRouterList, timeoutInterval: 15))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
    @ObservationIgnored var now: () -> Date = { Date() }
    /// What a server answers to `GET /models`; replaced by tests, which hold
    /// the answers back to put them in any order.
    @ObservationIgnored var fetchModels: (URL) async throws -> Data = { base in
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 3))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Next to the preferences; in test mode next to the state file.
    static let standardSpeedsFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("satz/cleanup-speeds.json")

    /// nil keeps everything in memory, for snapshots and tests.
    init(folder: URL? = LocalModels.root, speedsFile: URL? = standardSpeedsFile, onlyThisComputer: Bool = false) {
        self.folder = folder
        self.speedsFile = speedsFile
        self.onlyThisComputer = onlyThisComputer
        if let speedsFile, let data = try? Data(contentsOf: speedsFile),
           let kept = try? JSONDecoder().decode(CleanupSpeeds.self, from: data) {
            speeds = kept
        }
        if let kept = keptPrices() { listings = kept.listings }
    }

    // MARK: - Which provider and model

    /// What Settings shows: the one looked at, else the one in use.
    func shown(_ preferences: Preferences) -> CleanupProvider {
        looking ?? preferences.cleanupProvider
    }

    /// The model id: the one picked, or the first of the server at the address
    /// in use, for Ollama and LM Studio.
    func modelID(_ provider: CleanupProvider, _ preferences: Preferences) -> String {
        let stored = preferences.cleanupModel(for: provider)
        if stored.isEmpty, provider == .ollama || provider == .lmStudio {
            return installedModels(provider, address: preferences.cleanupAddress(for: provider))?.first ?? ""
        }
        return stored
    }

    /// What the server at `address` (as typed; empty is the provider's own)
    /// said it has; nil while it has not answered, or answered nothing.
    func installedModels(_ provider: CleanupProvider, address: String = "") -> [String]? {
        guard let server = Server(provider, address: address), case .models(let ids)? = discovered[server] else { return nil }
        return ids
    }

    /// The server at `address` was asked and did not answer.
    func isNotRunning(_ provider: CleanupProvider, address: String = "") -> Bool {
        guard let server = Server(provider, address: address) else { return false }
        return discovered[server] == .silent
    }

    func model(_ provider: CleanupProvider, _ preferences: Preferences) -> CleanupModel {
        model(modelID(provider, preferences), for: provider)
    }

    /// A model at today's price where OpenRouter has one.
    func model(_ id: String, for provider: CleanupProvider) -> CleanupModel {
        CleanupCatalog.model(id, for: provider, listing: provider == .openRouter ? listings[id] : nil)
    }

    /// The menu's models: the catalog, or what the server at `address` has.
    func models(_ provider: CleanupProvider, address: String = "") -> [CleanupModel] {
        switch provider {
        case .ollama, .lmStudio: (installedModels(provider, address: address) ?? []).map { model($0, for: provider) }
        default: CleanupCatalog.models(for: provider).map { model($0.id, for: provider) }
        }
    }

    /// Everything a cleanup with `provider` needs, read now. The key is read
    /// here and goes no further than the request.
    func job(_ provider: CleanupProvider, _ preferences: Preferences) -> CleanupJob {
        let id = modelID(provider, preferences)
        return CleanupJob(
            provider: provider,
            model: model(id, for: provider),
            address: preferences.cleanupAddress(for: provider),
            key: provider.keyAccount.flatMap { readKey($0.name) },
            level: preferences.cleanupLevel,
            customPrompt: preferences.cleanupPrompt,
            vocabulary: preferences.words,
            listing: provider == .openRouter ? listings[id] : nil,
            listKept: provider == .openRouter && !listings.isEmpty,
            onlyThisComputer: onlyThisComputer
        )
    }

    /// What `provider` lacks before it can clean up. `hasKey` is Setup's,
    /// which a fixture answers for every key.
    func missing(_ provider: CleanupProvider, _ preferences: Preferences, hasKey: (KeyAccount) -> Bool) -> [CleanupReadiness.Need] {
        CleanupReadiness.missing(provider, hasKey: provider.keyAccount.map(hasKey) ?? true,
                                 address: preferences.cleanupAddress(for: provider),
                                 model: modelID(provider, preferences), apple: appleState)
    }

    // MARK: - Estimates

    func estimate(_ model: CleanupModel, provider: CleanupProvider, preferences: Preferences, characters: Double) -> CleanupEstimate {
        CleanupEstimate(model: model, level: preferences.cleanupLevel, vocabulary: preferences.words,
                        customPrompt: preferences.cleanupPrompt, characters: characters,
                        measuredSeconds: speeds.seconds(provider, model: model.id))
    }

    // MARK: - Running

    /// One dictation's cleanup, with the provider in use. Its time is kept.
    ///
    /// A dictation that is discarded cancels this task. It then sends nothing
    /// more, and what it was told is neither measured nor logged: the answer
    /// is thrown away, and a request that was cut short says nothing about
    /// how fast the model is.
    func clean(_ text: String, _ preferences: Preferences) async -> CleanupResult {
        guard !Task.isCancelled else { return .cancelled(text) }
        let provider = preferences.cleanupProvider
        if provider == .apple { appleState = AppleCleanup.state }
        // Ollama's first model, when none was picked and Settings has not
        // asked it since satz started.
        if modelID(provider, preferences).isEmpty, provider == .ollama || provider == .lmStudio {
            await refreshInstalled(provider, address: preferences.cleanupAddress(for: provider))
            guard !Task.isCancelled else { return .cancelled(text) }
        }
        let job = job(provider, preferences)
        let result = await client.run(job, text: text)
        guard !Task.isCancelled else { return .cancelled(text) }
        record(job, result)
        let outcome = result.failure.map { "not cleaned up (\($0.code))" } ?? (result.cleaned == nil ? "nothing to clean" : "cleaned up")
        let timing = result.seconds.map { String(format: " after %.2f s", $0) } ?? ""
        Log.note("cleanup: \(outcome) by \(job.provider.rawValue) \(job.model.id)\(timing), \(text.count) → \(result.text.count) characters\(result.detail.map { ", \($0)" } ?? "")")
        return result
    }

    /// "Ausprobieren": the provider, model, level and prompt shown, which need
    /// not be the ones in use. Again while it runs: stops it.
    func tryOut(_ text: String, _ preferences: Preferences, then done: @escaping () -> Void = {}) {
        if trying {
            tryTask?.cancel()
            tryTask = nil
            trying = false
            return
        }
        let provider = shown(preferences)
        if provider == .apple { appleState = AppleCleanup.state }
        let job = job(provider, preferences)
        trying = true
        tried = nil
        tryTask = Task {
            let result = await client.run(job, text: text)
            guard !Task.isCancelled else { return }
            record(job, result)
            Log.note("cleanup try: \(result.failure?.code ?? "ok") by \(provider.rawValue) \(job.model.id)\(result.seconds.map { String(format: " after %.2f s", $0) } ?? "")\(result.detail.map { ", \($0)" } ?? "")")
            tried = Tried(provider: provider, model: job.model.id, result: result)
            trying = false
            tryTask = nil
            done()
        }
    }

    private func record(_ job: CleanupJob, _ result: CleanupResult) {
        guard result.answered, let seconds = result.seconds else { return }
        speeds.add(job.provider, model: job.model.id, seconds: seconds, dollars: result.dollars)
        guard let speedsFile, let data = try? JSONEncoder().encode(speeds) else { return }
        try? FileManager.default.createDirectory(at: speedsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: speedsFile, options: .atomic)
    }

    // MARK: - Asking around

    func refreshApple() {
        let state = AppleCleanup.state
        if state != appleState { appleState = state }
    }

    /// OpenRouter's prices again when the kept ones are older than a day, and
    /// not within ten minutes of a failure. Its list is public: no key goes
    /// with it. Windows and Linux wait the same.
    @discardableResult
    func refreshPrices() -> Task<Void, Never>? {
        guard folder != nil, !fetchingPrices else { return nil }
        if let failed = pricesFailed, now().timeIntervalSince(failed) < 10 * 60 { return nil }
        if let kept = keptPrices(), now().timeIntervalSince(kept.fetched) < 24 * 3600 { return nil }
        fetchingPrices = true
        return Task {
            defer { fetchingPrices = false }
            do {
                let fresh = try CleanupCatalog.parseOpenRouter(try await fetchPrices())
                listings = fresh
                pricesFailed = nil
                if let file = pricesFile, let data = try? JSONEncoder().encode(KeptPrices(fetched: now(), listings: fresh)) {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
                Log.note("cleanup: \(fresh.count) prices from OpenRouter")
            } catch {
                pricesFailed = now()
                Log.note("cleanup: OpenRouter prices not fetched (\(error.localizedDescription)), keeping \(listings.count)")
            }
        }
    }

    /// What Ollama or LM Studio has, asked when Settings shows the address and
    /// before a dictation that has no model picked. The answer is kept for
    /// that address only, and dropped when it is not the one asked last or
    /// not the newest answer of its server. Showing another address stops the
    /// ask that is running, when the view runs this in its `.task`.
    func refreshInstalled(_ provider: CleanupProvider, address: String) async {
        guard provider == .ollama || provider == .lmStudio else { return }
        let server = Server(provider, address: address)
        // An address that cannot be used is the last one asked as well: the
        // answer of the one before is not the server shown now.
        lastAsked[provider] = server
        guard let server, let base = CleanupAddress.url(provider.address(address)) else { return }
        asks += 1
        let ask = asks
        let found: Discovery
        do {
            // In OpenAI's format (`GET /models`).
            guard let models = CleanupCatalog.installedModels(in: try await fetchModels(base)) else { throw URLError(.badServerResponse) }
            found = .models(models)
        } catch {
            // Stopped, not unanswered: the view moved on, or the dictation was discarded.
            if Task.isCancelled { return }
            found = .silent
        }
        guard lastAsked[provider] == server, ask > answeredAt[server, default: 0] else { return }
        for old in discovered.keys where old.provider == provider && old != server {
            discovered[old] = nil
            answeredAt[old] = nil
        }
        discovered[server] = found
        answeredAt[server] = ask
    }

    // MARK: - On disk

    private struct KeptPrices: Codable {
        let fetched: Date
        let listings: [String: OpenRouterListing]
    }

    private var pricesFile: URL? { folder?.appendingPathComponent("cleanup-openrouter.json") }

    private func keptPrices() -> KeptPrices? {
        guard let file = pricesFile, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(KeptPrices.self, from: data)
    }

    // MARK: - Fixtures

    /// OpenRouter's list as fetched, for tests.
    func stageListings(_ listings: [String: OpenRouterListing]) {
        self.listings = listings
    }

    /// Fixed values, for snapshots.
    func stage(speeds: CleanupSpeeds = CleanupSpeeds(), installed: [CleanupProvider: [String]] = [:],
               apple: AppleCleanup.State = .available, tried: Tried? = nil, trying: Bool = false) {
        self.speeds = speeds
        // At the address a provider has until another is typed.
        discovered = Dictionary(uniqueKeysWithValues: installed.compactMap { provider, ids in
            Server(provider, address: "").map { ($0, Discovery.models(ids)) }
        })
        appleState = apple
        self.tried = tried
        self.trying = trying
    }
}
