import Foundation
import Observation

/// The last few transcripts, so a paste that went somewhere unexpected is not
/// a lost paragraph.
///
/// Kept across restarts in a file only the user can read (0600, like the API
/// keys), because a history that empties on every update looked broken. Only
/// the last few, and "Leeren" deletes them from disk too.
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

    /// The popover shows exactly this many: the newest in full, the rest as lines.
    static let limit = 4

    /// Where the history is kept. nil keeps it in memory only (fixtures).
    static let standardFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("satz/history.json")

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let file: URL?

    init(entries: [Entry] = [], file: URL? = nil) {
        self.file = file
        self.entries = entries
        if let file, entries.isEmpty, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = Array(stored.prefix(Self.limit))
        }
    }

    func add(_ text: String, app: String?, pasted: Bool, at date: Date = .now) {
        guard !text.isEmpty else { return }
        entries.insert(Entry(text: text, date: date, app: app, pasted: pasted), at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        // Created at 0600 before anything is written, so the text is never on
        // disk with looser permissions.
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: file)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
