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
    /// What Ollama and LM Studio have installed or loaded, once asked.
    private(set) var installed: [CleanupProvider: [String]] = [:]
    /// Asked, and nobody answered: the server is not running.
    private(set) var notRunning: Set<CleanupProvider> = []
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

    @ObservationIgnored private var tryTask: Task<Void, Never>?
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

    /// The model id: the one picked, or Ollama's and LM Studio's first.
    func modelID(_ provider: CleanupProvider, _ preferences: Preferences) -> String {
        let stored = preferences.cleanupModel(for: provider)
        if stored.isEmpty, provider == .ollama || provider == .lmStudio { return installed[provider]?.first ?? "" }
        return stored
    }

    func model(_ provider: CleanupProvider, _ preferences: Preferences) -> CleanupModel {
        model(modelID(provider, preferences), for: provider)
    }

    /// A model at today's price where OpenRouter has one.
    func model(_ id: String, for provider: CleanupProvider) -> CleanupModel {
        CleanupCatalog.model(id, for: provider, listing: provider == .openRouter ? listings[id] : nil)
    }

    /// The menu's models: the catalog, or what the server on this computer has.
    func models(_ provider: CleanupProvider) -> [CleanupModel] {
        switch provider {
        case .ollama, .lmStudio: (installed[provider] ?? []).map { model($0, for: provider) }
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
    func clean(_ text: String, _ preferences: Preferences) async -> CleanupResult {
        let provider = preferences.cleanupProvider
        if provider == .apple { appleState = AppleCleanup.state }
        // Ollama's first model, when none was picked and Settings has not
        // asked it since satz started.
        if modelID(provider, preferences).isEmpty, provider == .ollama || provider == .lmStudio {
            await fetchInstalled(provider, address: preferences.cleanupAddress(for: provider))
        }
        let job = job(provider, preferences)
        let result = await client.run(job, text: text)
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

    /// What Ollama or LM Studio has, asked when Settings shows it.
    func refreshInstalled(_ provider: CleanupProvider, address: String) {
        Task { await fetchInstalled(provider, address: address) }
    }

    /// What Ollama or LM Studio has, in OpenAI's format (`GET /models`).
    private func fetchInstalled(_ provider: CleanupProvider, address: String) async {
        guard provider == .ollama || provider == .lmStudio,
              let base = CleanupAddress.url(provider.address(address)) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 3))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let models = CleanupCatalog.installedModels(in: data) else { throw URLError(.badServerResponse) }
            installed[provider] = models
            notRunning.remove(provider)
        } catch {
            installed[provider] = nil
            notRunning.insert(provider)
        }
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
        self.installed = installed
        appleState = apple
        self.tried = tried
        self.trying = trying
    }
}
