import Foundation
import Observation

/// The last few transcripts, so a paste that went somewhere unexpected is not
/// a lost paragraph.
///
/// Held in memory only and gone when satz quits. This is somebody's speech; it
/// is not written to disk.
@MainActor
@Observable
final class History {

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
        /// The application it was dictated into, when known.
        let app: String?
        /// false when it only reached the clipboard.
        let pasted: Bool
    }

    /// The popover shows exactly this many: the newest in full, the rest as lines.
    static let limit = 4

    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    func add(_ text: String, app: String?, pasted: Bool, at date: Date = .now) {
        guard !text.isEmpty else { return }
        entries.insert(Entry(text: text, date: date, app: app, pasted: pasted), at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
