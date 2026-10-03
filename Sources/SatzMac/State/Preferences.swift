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
    var words: [String] {
        didSet { defaults?.set(words, forKey: Key.words) }
    }

    var trigger: Trigger {
        didSet { defaults?.set(try? JSONEncoder().encode(trigger), forKey: Key.trigger) }
    }

    var triggerMode: TriggerMode {
        didSet { defaults?.set(triggerMode.rawValue, forKey: Key.triggerMode) }
    }

    /// The microphone to record from, by Core Audio UID. nil follows whatever
    /// macOS has selected, which is what most people want: it switches with the
    /// AirPods or headset they just connected.
    var inputDeviceUID: String? {
        didSet { defaults?.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }

    /// Everything the transcriber needs, read fresh at send time so an edit in
    /// the settings window applies to the very next dictation.
    var transcriberSettings: Transcriber.Settings {
        var settings = Transcriber.Settings(
            provider: provider,
            model: model,
            customBaseURL: URL(string: customBaseURL.trimmingCharacters(in: .whitespaces))
        )
        settings.vocabulary = words
        return settings
    }

    /// A custom provider without a usable URL has nowhere to send the audio.
    var isEndpointMissing: Bool {
        provider == .custom && URL(string: customBaseURL.trimmingCharacters(in: .whitespaces))?.host == nil
    }

    func addWord(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        words.append(clean)
    }

    func removeWord(_ word: String) {
        words.removeAll { $0 == word }
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
        static let words = "words"
        /// The free-text field vocabulary used to be. Read once, then left alone.
        static let vocabulary = "vocabulary"
        static let trigger = "trigger"
        static let triggerMode = "triggerMode"
        static let inputDeviceUID = "inputDeviceUID"
    }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        provider = defaults?.string(forKey: Key.provider).flatMap(Provider.init(rawValue:)) ?? .openAI
        models = defaults?.dictionary(forKey: Key.models) as? [String: String] ?? [:]
        customBaseURL = defaults?.string(forKey: Key.customBaseURL) ?? ""
        words = defaults?.stringArray(forKey: Key.words)
            ?? Self.migratedWords(defaults?.string(forKey: Key.vocabulary))
        trigger = defaults?.data(forKey: Key.trigger).flatMap { try? JSONDecoder().decode(Trigger.self, from: $0) }
            ?? .standard
        triggerMode = defaults?.string(forKey: Key.triggerMode).flatMap(TriggerMode.init(rawValue:)) ?? .tap
        inputDeviceUID = defaults?.string(forKey: Key.inputDeviceUID)
    }

    /// The vocabulary used to be one comma-separated field.
    private static func migratedWords(_ old: String?) -> [String] {
        (old ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
