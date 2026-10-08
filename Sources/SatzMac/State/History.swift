import Foundation
import Observation

/// The last transcripts, so a paste that went somewhere unexpected is not a
/// lost paragraph, and something said yesterday can be found again.
///
/// Kept across restarts in a file only the user can read (0600, like the API
/// keys), because a history that empties on every update looked broken. As
/// many as the user chose (none at all is a choice), and "Leeren" deletes
/// them from disk too.
@MainActor
@Observable
final class History {

    struct Entry: Identifiable, Equatable, Codable {
        var id = UUID()
        let text: String
        let date: Date
        /// The application it was dictated into, when known.
        let app: String?
        /// false when it only reached the clipboard.
        let pasted: Bool
    }

    /// The menu shows this many: the newest in full, the rest as lines.
    static let shownInMenu = 4
    static let standardLimit = 50
    /// "All": no limit anyone would reach.
    static let keepAll = 100_000
    /// The choices in Settings, 0 being "keep none".
    static let limits = [0, 10, 50, 200, keepAll]

    /// Where the history is kept. nil keeps it in memory only (fixtures).
    static let standardFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("satz/history.json")

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let file: URL?
    /// How many are kept. Lowering it drops the oldest at once, from disk too.
    var limit: Int {
        didSet { trim() }
    }

    init(entries: [Entry] = [], file: URL? = nil, limit: Int = keepAll) {
        self.file = file
        self.limit = limit
        self.entries = entries
        if let file, entries.isEmpty, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = Array(stored.prefix(max(limit, 0)))
        }
    }

    func add(_ text: String, app: String?, pasted: Bool, at date: Date = .now) {
        // Off means nothing is written, not written and then forgotten.
        guard !text.isEmpty, limit > 0 else { return }
        entries.insert(Entry(text: text, date: date, app: app, pasted: pasted), at: 0)
        trim()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func trim() {
        guard limit > 0 else { return clear() }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        // Written beside it at 0600, so the text is never on disk with looser
        // permissions, then moved over the old file in one step: written in
        // place, an interrupted save left an empty history.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).new")
        try? manager.removeItem(at: temporary)
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, file.path) != 0 { try? manager.removeItem(at: temporary) }
    }
}
