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
    @ObservationIgnored private var fetching: Set<Provider> = []
    @ObservationIgnored private let folder: URL?

    /// nil keeps everything in memory, for snapshots and tests.
    init(folder: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("satz/models", isDirectory: true)) {
        self.folder = folder
    }

    func models(for provider: Provider) -> [ModelChoice] {
        if let list = lists[provider] { return list }
        return cached(provider)?.models ?? provider.models
    }

    /// Asks the provider again when the kept list is older than a day.
    func refresh(_ provider: Provider, force: Bool = false) {
        guard provider != .custom, !fetching.contains(provider) else { return }
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

    // MARK: - On disk

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
