import Foundation
import Observation
import SatzKit

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
        /// The text before cleanup, when what was pasted differs from it.
        var original: String? = nil
        /// nil when cleanup was off; "ok", or why it did not work ("Zu langsam").
        var cleanup: String? = nil
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
    enum StorageFailure: Equatable {
        case saving
        case deleting
    }
    /// The displayed entries remain usable even when their disk update fails.
    private(set) var storageFailure: StorageFailure?

    var storageWarningTitle: String? {
        switch storageFailure {
        case .saving: de("Verlauf nicht gespeichert", en: "History not saved")
        case .deleting: de("Verlauf nicht gelöscht", en: "History not cleared")
        case nil: nil
        }
    }

    var storageWarningDetail: String? {
        switch storageFailure {
        case .saving:
            de("Neue Texte und Änderungen bleiben nur bis zum Beenden in satz. Kopiere wichtige Texte vorher.",
               en: "New text and changes are kept in satz only until you quit. Copy important text first.")
        case .deleting:
            de("Gespeicherte Texte konnten hier nicht gelöscht werden. Sie können beim nächsten Start wieder erscheinen.",
               en: "Saved text could not be deleted here. It may appear again when satz next starts.")
        case nil: nil
        }
    }
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
        if limit <= 0 { clear() }
    }

    func add(_ text: String, app: String?, pasted: Bool, at date: Date = .now, original: String? = nil, cleanup: String? = nil) {
        // Off means nothing is written, not written and then forgotten.
        guard !text.isEmpty, limit > 0 else { return }
        entries.insert(Entry(text: text, date: date, app: app, pasted: pasted,
                             original: original == text ? nil : original, cleanup: cleanup), at: 0)
        trim()
    }

    /// How long the dictations are, newest first: what was said, before any
    /// cleanup. For the cleanup's estimate.
    var spokenLengths: [Int] {
        // As Unicode scalars, the way Windows and Linux count (`CleanupTiming.characters`).
        entries.map { CleanupTiming.characters($0.original ?? $0.text) }
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        guard let file else { storageFailure = nil; return }
        do {
            let manager = FileManager.default
            var directory: ObjCBool = false
            if manager.fileExists(atPath: file.path, isDirectory: &directory), directory.boolValue {
                // A history file is never a directory. Do not recursively
                // delete something else that appeared at the same path.
                throw CocoaError(.fileWriteNoPermission)
            }
            try manager.removeItem(at: file)
            storageFailure = nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            storageFailure = nil
        } catch {
            storageFailure = .deleting
        }
    }

    private func trim() {
        guard limit > 0 else { return clear() }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    private func save() {
        guard let file else { storageFailure = nil; return }
        let manager = FileManager.default
        // Written beside it at 0600, so the text is never on disk with looser
        // permissions, then moved over the old file in one step: written in
        // place, an interrupted save left an empty history.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).new")
        defer { try? manager.removeItem(at: temporary) }
        do {
            let data = try JSONEncoder().encode(entries)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(temporary.path, file.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            storageFailure = nil
        } catch {
            // A failed history update must never turn a completed paste into
            // Retry. Keep the entries usable and report disk state separately.
            storageFailure = .saving
        }
    }
}
