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

    /// Any provider's model, for Settings showing one that is not in use.
    func model(for provider: Provider) -> String {
        models[provider.rawValue] ?? provider.defaultModel
    }

    func setModel(_ id: String, for provider: Provider) {
        models[provider.rawValue] = id
    }

    /// The model for Lokal, whichever provider is chosen now: a download
    /// that finishes while another provider is chosen still sets it.
    var localModel: String {
        get { models[Provider.local.rawValue] ?? Provider.local.defaultModel }
        set { models[Provider.local.rawValue] = newValue }
    }

    /// Base URL for `.custom`, as typed. Ignored by the built-in providers.
    var customBaseURL: String {
        didSet { defaults?.set(customBaseURL, forKey: Key.customBaseURL) }
    }

    /// The region of the user's Azure Speech resource, for Microsoft: its host
    /// is built from it. A key only works in its own region.
    var microsoftRegion: String {
        didSet { defaults?.set(microsoftRegion, forKey: Key.microsoftRegion) }
    }

    /// The address of the user's own Speech resource, as typed, for
    /// Microsoft. Empty uses the region; an address wins over it.
    var microsoftEndpoint: String {
        didSet { defaults?.set(microsoftEndpoint, forKey: Key.microsoftEndpoint) }
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

    /// German or English, for the app itself.
    var language: Language {
        didSet {
            defaults?.set(language.rawValue, forKey: Key.language)
            Language.current = language
            if spokenChoice == nil { swapPredefinedReplacements(from: oldValue, to: language) }
        }
    }

    /// The language the user talks to satz in, which decides the predefined
    /// Ersetzungen and the trigger words the model is told to expect. The
    /// same as the app's until chosen: people keep the Mac in one language
    /// and talk in another.
    var spokenLanguage: Language {
        get { spokenChoice ?? language }
        set {
            let old = spokenLanguage
            spokenChoice = newValue
            defaults?.set(newValue.rawValue, forKey: Key.spokenLanguage)
            swapPredefinedReplacements(from: old, to: newValue)
        }
    }

    /// nil until the user picks a spoken language of their own.
    private var spokenChoice: Language?

    /// The language Canary is told it hears and writes, a code among its
    /// four ("es"); nil follows the spoken language. Kept apart from it:
    /// Whisper, the replacements and Apple's know only German and English.
    var toldLanguage: String? {
        didSet { defaults?.set(toldLanguage, forKey: Key.toldLanguage) }
    }

    /// The predefined rules of one language make way for the other's. The
    /// user's own rules stay; a predefined one they removed comes back.
    private func swapPredefinedReplacements(from old: Language, to new: Language) {
        guard old != new else { return }
        // Shipped only while unchanged: a rule the user turned on or gave
        // another symbol ("Klammer auf" to "[") was dropped by its phrase.
        let shipped = Replacements.standard(for: old)
        let own = replacements.filter { rule in
            !shipped.contains { $0.spoken.caseInsensitiveCompare(rule.spoken) == .orderedSame && $0.written == rule.written && $0.isOn == rule.isOn }
        }
        let ownPhrases = Set(own.map { $0.spoken.lowercased() })
        replacements = Replacements.standard(for: new).filter { !ownPhrases.contains($0.spoken.lowercased()) } + own
    }

    /// Where the user dragged the card, as an offset from where it starts:
    /// the pill centred near the bottom of the screen. nil until they move it.
    var cardOffset: CGPoint? {
        didSet {
            if let cardOffset {
                defaults?.set(["x": cardOffset.x, "y": cardOffset.y], forKey: Key.cardOffset)
            } else {
                defaults?.removeObject(forKey: Key.cardOffset)
            }
        }
    }

    /// The colour family: DPA+, forest, lavender or light blue.
    var appTheme: AppTheme {
        didSet {
            defaults?.set(appTheme.rawValue, forKey: Key.appTheme)
            AppTheme.current = appTheme
        }
    }

    /// Whether the card shows the text while dictating (the eye button).
    var showsText: Bool {
        didSet { defaults?.set(showsText, forKey: Key.showsText) }
    }

    /// Spoken words that become symbols: "Klammer auf" becomes "(".
    var replacements: [Replacement] {
        didSet { defaults?.set(try? JSONEncoder().encode(replacements), forKey: Key.replacements) }
    }

    /// Whether Ersetzungen are applied at all. Off keeps the list for later.
    var usesReplacements: Bool {
        didSet { defaults?.set(usesReplacements, forKey: Key.usesReplacements) }
    }

    /// The rules to apply now: the list, or nothing while switched off.
    var activeReplacements: [Replacement] {
        usesReplacements ? replacements : []
    }

    /// How many dictations the history keeps: 0 keeps none, `History.keepAll`
    /// every one.
    var historyLimit: Int {
        didSet { defaults?.set(historyLimit, forKey: Key.historyLimit) }
    }

    /// Music and videos pause while dictating, and play on afterwards.
    var pausesMedia: Bool {
        didSet { defaults?.set(pausesMedia, forKey: Key.pausesMedia) }
    }

    /// The dictated text stays on the clipboard after pasting, instead of
    /// what was copied before coming back.
    var keepsOnClipboard: Bool {
        didSet { defaults?.set(keepsOnClipboard, forKey: Key.keepsOnClipboard) }
    }

    /// MAI-Transcribe's clean mode and Gemini's smart mode: no "ähm", no
    /// stutters, no false starts.
    var removesFillers: Bool {
        didSet { defaults?.set(removesFillers, forKey: Key.removesFillers) }
    }

    /// Everything the transcriber needs, read fresh at send time so an edit in
    /// the settings window applies to the very next dictation.
    var transcriberSettings: Transcriber.Settings {
        var settings = Transcriber.Settings(
            provider: provider,
            model: model,
            customBaseURL: URL(string: customBaseURL.trimmingCharacters(in: .whitespaces)),
            microsoftRegion: microsoftRegion,
            microsoftEndpoint: microsoftEndpoint
        )
        // Trigger words go in too: a made-up one only survives transcription
        // if the model was told to expect it.
        settings.vocabulary = words + Replacements.phrases(activeReplacements)
        settings.removesFillers = removesFillers
        return settings
    }

    /// A custom provider without a usable URL has nowhere to send the audio,
    /// and neither has Microsoft with an own address typed that cannot work.
    var isEndpointMissing: Bool {
        switch provider {
        case .custom: !ProviderReadiness.hasUsableAddress(customBaseURL)
        case .microsoft: missing(.microsoft, hasKey: true).contains(.address)
        default: false
        }
    }

    /// A custom endpoint has no default model; without one every request fails.
    var isModelMissing: Bool {
        provider == .custom && !ProviderReadiness.hasModel(model)
    }

    /// What `provider` still lacks before it can take a dictation, in use or
    /// not. `hasKey` is its key being saved, or for Lokal its model being on
    /// this Mac (`Setup` knows).
    func missing(_ provider: Provider, hasKey: Bool) -> [ProviderReadiness.Need] {
        ProviderReadiness.missing(provider, hasKey: hasKey, customBaseURL: customBaseURL, model: model(for: provider),
                                  microsoftEndpoint: microsoftEndpoint)
    }

    func addWord(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !Restoring.containsWord(clean, in: words) else { return }
        words.append(clean)
    }

    func removeWord(_ word: String) {
        words.removeAll { $0 == word }
    }

    /// Undo of `removeWord`: not when the word is there again. Added a second
    /// time, it stood twice in the list, with one identity for both rows.
    func restoreWord(_ word: String, at index: Int) {
        let restored = Restoring.word(word, at: index, in: words)
        if restored != words { words = restored }
    }

    /// Undo of removing a rule: not when its phrase has a rule again, which
    /// is the newer one and must win (the first match in the list does).
    func restoreReplacement(_ rule: Replacement, at index: Int) {
        let restored = Restoring.rule(rule, at: index, in: replacements)
        if restored != replacements { replacements = restored }
    }

    private var models: [String: String] {
        didSet { defaults?.set(models, forKey: Key.models) }
    }

    /// nil keeps everything in memory, for fixtures that must not touch disk.
    private let defaults: UserDefaults?

    /// Changes whenever something that every label or colour depends on
    /// does, for `.id(...)` at the root of each window.
    var lookKey: String { "\(language.rawValue)-\(appTheme.rawValue)" }

    private enum Key {
        static let provider = "provider"
        static let models = "models"
        static let customBaseURL = "customBaseURL"
        static let microsoftRegion = "microsoftRegion"
        static let microsoftEndpoint = "microsoftEndpoint"
        static let words = "words"
        /// The free-text field vocabulary used to be. Read once, then left alone.
        static let vocabulary = "vocabulary"
        static let trigger = "trigger"
        static let triggerMode = "triggerMode"
        static let inputDeviceUID = "inputDeviceUID"
        static let language = "language"
        static let spokenLanguage = "spokenLanguage"
        static let toldLanguage = "toldLanguage"
        static let showsText = "showsText"
        static let appTheme = "appTheme"
        /// "cardOffset" before 04.10. measured from another spot; dropped.
        static let cardOffset = "cardSpot"
        static let replacements = "replacements"
        static let removesFillers = "removesFillers"
        static let usesReplacements = "usesReplacements"
        static let keepsOnClipboard = "keepsOnClipboard"
        static let historyLimit = "historyLimit"
        static let pausesMedia = "pausesMedia"
    }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        // OpenRouter with MAI-Transcribe 2, as the README says. Someone who
        // set up satz before with an OpenAI key and never touched the switch
        // has no stored provider: they stay on OpenAI.
        provider = defaults?.string(forKey: Key.provider).flatMap(Provider.init(rawValue:))
            ?? (defaults != nil && Secrets.exists(for: .openAI) && !Secrets.exists(for: .openRouter) ? .openAI : .openRouter)
        models = defaults?.dictionary(forKey: Key.models) as? [String: String] ?? [:]
        customBaseURL = defaults?.string(forKey: Key.customBaseURL) ?? ""
        microsoftRegion = defaults?.string(forKey: Key.microsoftRegion) ?? MicrosoftSpeech.defaultRegion
        microsoftEndpoint = defaults?.string(forKey: Key.microsoftEndpoint) ?? ""
        words = defaults?.stringArray(forKey: Key.words)
            ?? Self.migratedWords(defaults?.string(forKey: Key.vocabulary))
        trigger = defaults?.data(forKey: Key.trigger).flatMap { try? JSONDecoder().decode(Trigger.self, from: $0) }
            ?? .standard
        triggerMode = defaults?.string(forKey: Key.triggerMode).flatMap(TriggerMode.init(rawValue:)) ?? .tap
        inputDeviceUID = defaults?.string(forKey: Key.inputDeviceUID)
        showsText = defaults?.object(forKey: Key.showsText) as? Bool ?? true
        let appTheme = defaults?.string(forKey: Key.appTheme).flatMap(AppTheme.init(rawValue:)) ?? .dpa
        self.appTheme = appTheme
        cardOffset = (defaults?.dictionary(forKey: Key.cardOffset) as? [String: Double])
            .flatMap { values in values["x"].flatMap { x in values["y"].map { CGPoint(x: x, y: $0) } } }
        // Only when there is something to drop: removing a key that is not
        // there still creates the preferences file, which a `--snapshot` run
        // must not do.
        if defaults?.object(forKey: "cardOffset") != nil { defaults?.removeObject(forKey: "cardOffset") }
        let language = defaults?.string(forKey: Key.language).flatMap(Language.init(rawValue:)) ?? .system
        self.language = language
        let spokenChoice = defaults?.string(forKey: Key.spokenLanguage).flatMap(Language.init(rawValue:))
        self.spokenChoice = spokenChoice
        toldLanguage = defaults?.string(forKey: Key.toldLanguage)
        replacements = defaults?.data(forKey: Key.replacements)
            .flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) }
            ?? Replacements.standard(for: spokenChoice ?? language)
        removesFillers = defaults?.object(forKey: Key.removesFillers) as? Bool ?? true
        usesReplacements = defaults?.object(forKey: Key.usesReplacements) as? Bool ?? true
        keepsOnClipboard = defaults?.bool(forKey: Key.keepsOnClipboard) ?? false
        historyLimit = defaults?.object(forKey: Key.historyLimit) as? Int ?? History.standardLimit
        pausesMedia = defaults?.object(forKey: Key.pausesMedia) as? Bool ?? true
        // Only the real, stored preferences set the app-wide language and
        // colours; a fixture made for a snapshot must not reset them.
        if defaults != nil {
            Language.current = language
            AppTheme.current = appTheme
        }
    }

    /// The vocabulary used to be one comma-separated field.
    private static func migratedWords(_ old: String?) -> [String] {
        (old ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
