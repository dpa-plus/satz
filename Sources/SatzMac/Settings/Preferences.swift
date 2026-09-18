import Foundation
import Observation
import SatzKit

/// What the user can adjust. Deliberately short: every setting added here is one
/// more thing to understand before the app is useful.
@MainActor
@Observable
final class Preferences {

    /// Where the audio goes. Each provider keeps its own key and model, so
    /// switching back and forth loses nothing.
    var provider: Provider {
        didSet { defaults?.set(provider.rawValue, forKey: Key.provider) }
    }

    /// The model for the current provider. Empty means the provider's default.
    var model: String {
        get { models[provider.rawValue] ?? provider.defaultModel }
        set { models[provider.rawValue] = newValue }
    }

    /// Base URL for `.custom`, as typed. Ignored by the built-in providers.
    var customBaseURL: String {
        didSet { defaults?.set(customBaseURL, forKey: Key.customBaseURL) }
    }

    /// Names, jargon and spellings sent with every transcription to bias
    /// recognition. Not a second model and not a rewrite: the endpoint's own
    /// `prompt` parameter.
    var vocabulary: String {
        didSet { defaults?.set(vocabulary, forKey: Key.vocabulary) }
    }

    /// Everything the transcriber needs, read fresh at send time so an edit in
    /// the settings window applies to the very next dictation.
    var transcriberSettings: Transcriber.Settings {
        var settings = Transcriber.Settings(
            provider: provider,
            model: model,
            customBaseURL: URL(string: customBaseURL.trimmingCharacters(in: .whitespaces))
        )
        settings.vocabulary = vocabulary
        return settings
    }

    /// A custom provider without a usable URL has nowhere to send the audio.
    var isEndpointMissing: Bool {
        provider == .custom && URL(string: customBaseURL.trimmingCharacters(in: .whitespaces))?.host == nil
    }

    private var models: [String: String] {
        didSet { defaults?.set(models, forKey: Key.models) }
    }

    /// nil keeps everything in memory, for fixtures that must not touch disk.
    private let defaults: UserDefaults?

    private enum Key {
        static let provider = "provider"
        static let models = "models"
        static let customBaseURL = "customBaseURL"
        static let vocabulary = "vocabulary"
    }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        provider = defaults?.string(forKey: Key.provider).flatMap(Provider.init(rawValue:)) ?? .openAI
        models = defaults?.dictionary(forKey: Key.models) as? [String: String] ?? [:]
        customBaseURL = defaults?.string(forKey: Key.customBaseURL) ?? ""
        vocabulary = defaults?.string(forKey: Key.vocabulary) ?? ""
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
