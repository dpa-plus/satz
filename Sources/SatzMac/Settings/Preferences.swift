import Foundation
import Observation

/// What the user can adjust. Deliberately short: every setting added here is one
/// more thing to understand before the app is useful.
@MainActor
@Observable
final class Preferences {

    /// Names, jargon and spellings sent with every transcription to bias
    /// recognition. Not a second model and not a rewrite: the endpoint's own
    /// `prompt` parameter.
    var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let vocabulary = "vocabulary"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
    }
}

/// The last few transcripts, so a paste that went somewhere unexpected is not a
/// lost paragraph.
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
    }

    static let limit = 5

    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    func add(_ text: String, at date: Date = .now) {
        guard !text.isEmpty else { return }
        entries.insert(Entry(text: text, date: date), at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }
}
