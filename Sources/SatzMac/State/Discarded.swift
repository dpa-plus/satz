import AppKit
import Observation

/// The last dictation thrown away with ×, so a slip of the hand is not a
/// lost paragraph. Only the last one, in memory only, like the history.
@MainActor
@Observable
final class Discarded {

    struct Snapshot {
        let text: NSAttributedString
        let segments: [Int: Session.Segment]
        let activeID: Int?
        let nextID: Int
        let origin: NSRunningApplication?
        /// What the menu shows.
        let preview: String
    }

    private(set) var last: Snapshot?

    func keep(_ snapshot: Snapshot) {
        last = snapshot
    }

    /// Hands the snapshot back and forgets it: it is back in the card.
    func take() -> Snapshot? {
        defer { last = nil }
        return last
    }
}
