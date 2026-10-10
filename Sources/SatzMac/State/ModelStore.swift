import Foundation
import Observation
import SatzKit

/// The models each provider offers, for the settings' menu: the provider's own
/// list, fetched when the settings open and kept on disk for a day, so new
/// models appear without a new satz. Until it arrives, and whenever it cannot,
/// the list satz ships with.
@MainActor
@Observable
final class ModelStore {

    private(set) var lists: [Provider: [ModelChoice]] = [:]
    /// What Argmax measured for the local models: errors, and speed per chip.
    private(set) var benchmarks: LocalBenchmarks = .bundled
    @ObservationIgnored private var fetching: Set<Provider> = []
    @ObservationIgnored private var fetchingBenchmarks = false
    @ObservationIgnored private let folder: URL?

    /// nil keeps everything in memory, for snapshots and tests. In test mode
    /// with `--models-dir`, that folder, like every model file.
    init(folder: URL? = LocalModels.root) {
        self.folder = folder
        if let kept = keptBenchmarks() { benchmarks = kept.benchmarks }
    }

    func models(for provider: Provider) -> [ModelChoice] {
        if let list = lists[provider] { return list }
        return cached(provider)?.models ?? provider.models
    }

    /// Asks the provider again when the kept list is older than a day.
    func refresh(_ provider: Provider, force: Bool = false) {
        guard ModelCatalog.hasLiveList(provider), !fetching.contains(provider) else { return }
        if let kept = cached(provider) {
            lists[provider] = kept.models
            if !force, Date().timeIntervalSince(kept.fetched) < 24 * 3600 { return }
        }
        fetching.insert(provider)
        Task {
            defer { fetching.remove(provider) }
            do {
                let models = try await ModelCatalog.fetch(provider, key: Secrets.read(for: provider))
                lists[provider] = models
                keep(Kept(fetched: Date(), models: models), for: provider)
                Log.note("models: \(models.count) from \(provider.name)")
            } catch {
                Log.note("models: \(provider.name) list not fetched (\(error.localizedDescription)), keeping \(models(for: provider).count)")
            }
        }
    }

    /// Argmax's numbers again when the kept ones are older than a day; the
    /// ones satz ships with until then, and whenever they cannot be read.
    func refreshBenchmarks() {
        guard folder != nil, !fetchingBenchmarks else { return }
        if let kept = keptBenchmarks(), Date().timeIntervalSince(kept.fetched) < 24 * 3600 { return }
        fetchingBenchmarks = true
        Task {
            defer { fetchingBenchmarks = false }
            do {
                let fresh = try await LocalBenchmarks.fetch()
                benchmarks = fresh
                if let folder, let data = try? JSONEncoder().encode(KeptBenchmarks(fetched: Date(), benchmarks: fresh)) {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? data.write(to: folder.appendingPathComponent(Self.benchmarksFile))
                }
                Log.note("models: local benchmarks from Argmax, \(fresh.speed.values.map(\.count).reduce(0, +)) chip speeds")
            } catch {
                Log.note("models: local benchmarks not fetched (\(error.localizedDescription)), keeping what there is")
            }
        }
    }

    // MARK: - On disk

    private static let benchmarksFile = "local-benchmarks.json"

    private struct KeptBenchmarks: Codable {
        let fetched: Date
        let benchmarks: LocalBenchmarks
    }

    private func keptBenchmarks() -> KeptBenchmarks? {
        guard let file = folder?.appendingPathComponent(Self.benchmarksFile), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(KeptBenchmarks.self, from: data)
    }

    private struct Kept: Codable {
        let fetched: Date
        let models: [ModelChoice]
    }

    private func file(_ provider: Provider) -> URL? {
        folder?.appendingPathComponent("\(provider.rawValue).json")
    }

    private func cached(_ provider: Provider) -> Kept? {
        guard let file = file(provider), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Kept.self, from: data)
    }

    private func keep(_ kept: Kept, for provider: Provider) {
        guard let folder, let file = file(provider), let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file)
    }
}
