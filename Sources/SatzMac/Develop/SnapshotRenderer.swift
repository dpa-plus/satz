import AppKit
import SatzKit
import SwiftUI

/// Renders satz's surfaces straight to PNGs, without ever putting a window on
/// screen.
///
/// `satz --snapshot <directory>` writes one PNG per surface, light and dark,
/// in fixed example states. This is how the interface gets looked at during
/// development: no window taking over the desktop, no screen recording
/// permission, and every state at once.
@MainActor
enum SnapshotRenderer {

    static func write(to directory: String) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // German first, then English, each sheet built after its language is
        // set, since every label reads it when the view is made.
        let sheets: [(String, Language, () -> AnyView)] = [
            ("card", .german, { AnyView(cardSheet) }),
            ("card-en", .english, { AnyView(cardSheet) }),
            ("menu-light", .german, { AnyView(menuSheet.environment(\.theme, .light)) }),
            ("menu-dark", .german, { AnyView(menuSheet.environment(\.theme, .dark)) }),
            ("menu-en", .english, { AnyView(menuSheet.environment(\.theme, .dark)) }),
            ("settings-light", .german, { AnyView(settingsSheet.environment(\.theme, .light)) }),
            ("settings-dark", .german, { AnyView(settingsSheet.environment(\.theme, .dark)) }),
            ("settings-en", .english, { AnyView(settingsSheet.environment(\.theme, .dark)) }),
            ("settings-microsoft", .german, { AnyView(settingsSheet(.microsoft).environment(\.theme, .light)) }),
            ("settings-microsoft-en", .english, { AnyView(settingsSheet(.microsoft).environment(\.theme, .dark)) }),
            ("settings-microsoft-address", .german, { AnyView(settingsSheet(.microsoft, endpoint: "https://satz-speech.cognitiveservices.azure.com").environment(\.theme, .light)) }),
            ("settings-microsoft-nokey", .german, { AnyView(settingsSheet(.microsoft, hasKey: false).environment(\.theme, .dark)) }),
            ("settings-google", .german, { AnyView(settingsSheet(.google).environment(\.theme, .light)) }),
            ("settings-google-en", .english, { AnyView(settingsSheet(.google).environment(\.theme, .dark)) }),
            ("settings-browse-microsoft", .german, { AnyView(settingsSheet(.openRouter).environment(\.showsProvider, .microsoft).environment(\.theme, .light)) }),
            ("setup-key", .german, { AnyView(setupSheet(.key).environment(\.theme, .light)) }),
            ("settings-local", .german, { AnyView(localSettingsSheet.environment(\.theme, .dark)) }),
            ("settings-local-en", .english, { AnyView(localSettingsSheet.environment(\.theme, .light)) }),
            ("settings-local-browse", .german, { AnyView(localBrowseSheet.environment(\.theme, .dark)) }),
            ("settings-local-canary", .german, { AnyView(localCanarySheet.environment(\.theme, .light)) }),
            ("settings-local-canary-en", .english, { AnyView(localCanarySheet.environment(\.theme, .dark)) }),
            ("settings-local-cohere", .german, { AnyView(localCohereSheet.environment(\.theme, .light)) }),
            ("settings-local-cohere-en", .english, { AnyView(localCohereSheet.environment(\.theme, .dark)) }),
            ("setup-local", .german, { AnyView(localSetupSheet.environment(\.theme, .light)) }),
            ("setup-local-en", .english, { AnyView(localSetupSheet.environment(\.theme, .dark)) }),
            ("setup-custom", .german, { AnyView(setupSheet(.key, provider: .custom).environment(\.theme, .light)) }),
            ("setup-microsoft", .german, { AnyView(setupSheet(.key, provider: .microsoft).environment(\.theme, .light)) }),
            ("setup-microsoft-en", .english, { AnyView(setupSheet(.key, provider: .microsoft).environment(\.theme, .dark)) }),
            ("setup-microsoft-address", .english, { AnyView(setupSheet(.key, provider: .microsoft, endpoint: "https://satz-speech.cognitiveservices.azure.com").environment(\.theme, .light)) }),
            ("setup-google", .german, { AnyView(setupSheet(.key, provider: .google).environment(\.theme, .light)) }),
            ("history", .german, { AnyView(historySheet.environment(\.theme, .light)) }),
            ("history-en", .english, { AnyView(historySheet.environment(\.theme, .dark)) }),
            ("setup-probe", .german, { AnyView(setupSheet(.probe).environment(\.theme, .light)) }),
            // The cleanup block alone, at full size: on, "Leicht", OpenRouter with an estimate.
            ("cleanup", .german, { AnyView(cleanupSheet(.light).environment(\.theme, .light)) }),
            ("cleanup-en", .english, { AnyView(cleanupSheet(.light).environment(\.theme, .dark)) }),
            // The own prompt, a model measured on this Mac, a try that was rejected.
            ("cleanup-custom", .german, { AnyView(cleanupSheet(.custom).environment(\.theme, .dark)) }),
            ("cleanup-custom-en", .english, { AnyView(cleanupSheet(.custom).environment(\.theme, .light)) }),
            // The prompt shown, Apple looked at while OpenRouter is in use, no key for it.
            ("cleanup-browse", .german, { AnyView(cleanupSheet(.smooth, browsing: .apple).environment(\.showsCleanupPrompt, true).environment(\.theme, .light)) }),
            ("cleanup-ollama", .german, { AnyView(cleanupSheet(.punctuation, provider: .ollama).environment(\.theme, .dark)) }),
            // A provider with no key yet: "Schlüssel holen" opens the page where one is made.
            ("cleanup-key", .german, { AnyView(cleanupSheet(.light, browsing: .anthropic).environment(\.theme, .light)) }),
            ("cleanup-key-en", .english, { AnyView(cleanupSheet(.light, browsing: .azure).environment(\.theme, .dark)) }),
            // The whole window, with the block where it sits.
            ("settings-cleanup", .german, { AnyView(settingsSheet(.openRouter, cleanup: true).environment(\.theme, .light)) }),
        ]
        for (name, language, view) in sheets {
            Language.current = language
            AppTheme.current = .dpa
            try png(of: view().environment(\.isSnapshot, true)).write(to: folder.appendingPathComponent("\(name).png"))
        }
        // Every colour family, light and dark, on one sheet each.
        for family in AppTheme.allCases {
            Language.current = .english
            AppTheme.current = family
            let sheet = HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 18) {
                    card(.listening, text: "Thanks for the update. Thursday works for me. ", marker: true)
                    card(.listening, marker: true)
                    card(.paused, text: "Thanks for the update.")
                }
                menuSheet.environment(\.theme, .light)
            }
            .padding(28)
            .background(Color(hex: 0xC9D4D8))
            try png(of: sheet.environment(\.isSnapshot, true)).write(to: folder.appendingPathComponent("theme-\(family.rawValue).png"))
            try png(of: settingsSheet.environment(\.theme, family.dark).environment(\.isSnapshot, true))
                .write(to: folder.appendingPathComponent("settings-\(family.rawValue).png"))
        }
        AppTheme.current = .dpa
        let icons = IconRenderer.tile.scaleEffect(0.18).frame(width: 184, height: 184)
            .padding(20)
            .background(Color(hex: 0x2A2A2A))
        try png(of: icons).write(to: folder.appendingPathComponent("icons.png"))
    }

    /// The README's picture: the card while talking, and the menu with what
    /// was dictated. In English and made up, never anyone's real text.
    static func writeShowcase(to path: String) throws {
        Language.current = .english
        AppTheme.current = .dpa
        let history = History()
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        history.add("The test is red, please don't merge yet.", app: "Slack", pasted: true, at: base)
        history.add("Let's move the call with Lena to Thursday at two.", app: "Mail", pasted: true, at: base + 600)
        history.add("Write a function that reads every invoice in the Accounting folder and adds up the totals per customer.",
                    app: "Claude", pasted: true, at: base + 1200)
        let sheet = HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .trailing, spacing: 28) {
                card(.listening, text: "Thanks for the update. Thursday at two works for me, and I'll bring the slides. ", marker: true)
                card(.listening, marker: true)
            }
            PopoverView(history: history, discarded: Discarded(), setup: Setup(hasKey: true, microphone: .allowed, canPaste: true),
                        shortcut: shortcut, preferences: preferences, actions: PopoverActions())
                .environment(\.theme, .light)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 44)
        // Rounded like the hero above it in the README.
        .background(Color(hex: 0xE9DDD2), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        try png(of: sheet.environment(\.isSnapshot, true)).write(to: URL(fileURLWithPath: path))
    }

    static func png(of view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }

    // MARK: - Fixtures

    /// In memory: a snapshot must never write to the user's preferences.
    private static var preferences: Preferences {
        let preferences = Preferences(defaults: nil)
        preferences.language = Language.current
        preferences.provider = .openRouter
        preferences.words = ["Kubernetes", "Grafana", "Figma"]
        return preferences
    }

    private static var history: History {
        let history = History()
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        history.add("Der Test ist rot, bitte nicht mergen.", app: "Slack", pasted: true, at: base)
        history.add("Termin mit Lena auf Donnerstag 14 Uhr verschieben.", app: "Mail", pasted: true, at: base + 600)
        history.add("Kannst du mir eine Funktion schreiben, die alle Rechnungen aus dem Ordner Buchhaltung liest und die Beträge pro Kunde summiert?",
                    app: "Claude", pasted: true, at: base + 1200)
        return history
    }

    /// Two days of dictations, for the history window.
    private static var longHistory: History {
        let history = History(limit: History.standardLimit)
        let now = Date()
        let texts: [(String, String?, Bool, TimeInterval)] = [
            ("The test is red, please don't merge yet.", "Slack", true, -26 * 3600),
            ("Let's move the call with Lena to Thursday at two.", "Mail", true, -25 * 3600),
            ("Bitte schick mir die Unterlagen bis Freitag, dann schaue ich sie mir am Wochenende an.", nil, false, -3 * 3600),
            ("Write a function that reads every invoice in the Accounting folder and adds up the totals per customer, without credit notes.", "Claude", true, -40 * 60),
            ("Thanks for the update. Thursday at two works for me, and I'll bring the slides.", "Mail", true, -5 * 60),
        ]
        for (text, app, pasted, offset) in texts {
            history.add(text, app: app, pasted: pasted, at: now.addingTimeInterval(offset))
        }
        // One cleaned up, with what was said behind "Original"; one that was not.
        history.add("Can we move the meeting to Tuesday? And who else is coming?", app: "Slack", pasted: true,
                    at: now.addingTimeInterval(-2 * 60),
                    original: "um so can we move the meeting to monday no tuesday and uh who else is coming",
                    cleanup: "ok")
        history.add("Bitte denk an die Folien für morgen.", app: "Mail", pasted: true, at: now.addingTimeInterval(-60),
                    cleanup: Language.current == .english ? "Too slow" : "Zu langsam")
        return history
    }

    private static var historySheet: some View {
        MainView(navigation: MainNavigation(), history: longHistory, preferences: preferences,
                 setup: Setup(hasKey: true, microphone: .allowed, canPaste: true), shortcut: shortcut,
                 launchAtLogin: LaunchAtLogin(), models: ModelStore(folder: nil), cleanups: CleanupStore(folder: nil, speedsFile: nil))
    }

    private static var shortcut: Shortcut {
        Shortcut(preferences: preferences, onPress: {}, onRelease: {})
    }

    // MARK: - Sheets

    private static let speech: [Float] = [0.1, 0.3, 0.55, 0.8, 0.62, 0.35, 0.5, 0.75, 0.9, 0.6, 0.3, 0.45]

    private static func card(_ phase: Session.Phase, text: String = "", marker: Bool = false, cleaning: Bool = false,
                             microphoneLost: Bool = false) -> some View {
        let session = Session(preferences: preferences, history: History(), discarded: Discarded())
        session.stage(phase, text: text, marker: marker, levels: phase == .listening ? speech : [], cleaning: cleaning,
                      microphoneLost: microphoneLost)
        return CardView(session: session, preferences: preferences)
    }

    private static var cardSheet: some View {
        let text = "Schreib mir eine Funktion, die alle Rechnungen aus dem Ordner liest. Dann soll sie die Beträge summieren."
        return VStack(spacing: 22) {
            card(.listening, marker: true)
            card(.listening, text: text + " ", marker: true)
            // A pause with nothing typed yet is the small pill: its word has to fit.
            card(.paused)
            card(.paused, text: text)
            // The microphone was unplugged: paused by itself, with and without the text above it.
            card(.paused, microphoneLost: true)
            card(.paused, text: text, microphoneLost: true)
            card(.finishing, text: text)
            card(.finishing, text: text, cleaning: true)
            card(.failed("Keine Verbindung", canRetry: true), text: text)
            card(.discarded)
            card(.clipboard)
            card(.notCleaned)
        }
        .padding(28)
        .background(Color(hex: 0xE9DDD2))
    }

    private static var discardedFixture: Discarded {
        let discarded = Discarded()
        discarded.keep(.init(text: NSAttributedString(string: "Bitte schick mir die Unterlagen bis Freitag."),
                             segments: [:], activeID: nil, nextID: 1, origin: nil,
                             preview: "Bitte schick mir die Unterlagen bis Freitag."))
        return discarded
    }

    private static var menuSheet: some View {
        HStack(alignment: .top, spacing: 24) {
            PopoverView(history: history, discarded: Discarded(), setup: Setup(hasKey: true, microphone: .allowed, canPaste: true),
                        shortcut: shortcut, preferences: preferences, actions: PopoverActions())
            PopoverView(history: History(), discarded: Discarded(), setup: Setup(hasKey: true, microphone: .allowed, canPaste: true),
                        shortcut: shortcut, preferences: preferences, actions: PopoverActions())
            PopoverView(history: history, discarded: discardedFixture,
                        setup: Setup(hasKey: true, microphone: .allowed, canPaste: false),
                        shortcut: shortcut, preferences: preferences, actions: PopoverActions())
        }
        .padding(28)
        .background(Color(hex: 0xC9D4D8))
    }

    private static var settingsSheet: some View { settingsSheet(.openRouter) }

    private static func settingsSheet(_ provider: Provider, localModel: String = LocalCatalog.parakeetV3,
                                      toldLanguage: String? = nil, endpoint: String = "", hasKey: Bool = true,
                                      cleanup: Bool = false) -> some View {
        let preferences = preferences
        preferences.provider = provider
        preferences.localModel = localModel
        preferences.toldLanguage = toldLanguage
        preferences.microsoftEndpoint = endpoint
        preferences.cleansText = cleanup
        let cleanups = CleanupStore(folder: nil, speedsFile: nil)
        cleanups.stage()
        return SettingsView(
            preferences: preferences,
            setup: Setup(hasKey: hasKey, microphone: .allowed, canPaste: true),
            shortcut: shortcut,
            launchAtLogin: LaunchAtLogin(),
            history: history,
            models: ModelStore(folder: nil),
            cleanups: cleanups
        )
    }

    /// The cleanup block on its own, as wide as in the window.
    private static func cleanupSheet(_ level: CleanupLevel, provider: CleanupProvider = .openRouter,
                                     browsing: CleanupProvider? = nil) -> some View {
        let preferences = preferences
        preferences.cleansText = true
        preferences.cleanupProvider = provider
        let store = CleanupStore(folder: nil, speedsFile: nil)
        let measured = Date(timeIntervalSince1970: 1_791_000_000)
        var speeds = CleanupSpeeds()
        var tried: CleanupStore.Tried?
        switch level {
        case .custom:
            // Picked after "Leicht": the field starts with its instructions.
            preferences.chooseCleanupLevel(.light)
            preferences.chooseCleanupLevel(.custom)
            preferences.cleanupPrompt += " Answer in the dictation's language, as a short email with a greeting."
            preferences.setCleanupModel("anthropic/claude-haiku-5.5", for: .openRouter)
            for seconds in [0.9, 1.1, 0.8] {
                speeds.add(.openRouter, model: "anthropic/claude-haiku-5.5", seconds: seconds, dollars: 0.00021, at: measured)
            }
            // The own prompt asked for a mail: nothing judges it but the user.
            let mail = Language.current == .english
                ? "Hi,\n\ncan we move the meeting to Tuesday? And who else is coming?\n\nBest"
                : "Hallo,\n\nkönnen wir das Meeting auf Dienstag legen? Und wer kommt noch?\n\nViele Grüße"
            tried = .init(provider: .openRouter, model: "anthropic/claude-haiku-5.5",
                          result: CleanupResult(text: mail, cleaned: mail, seconds: 0.92, dollars: 0.00019))
        default:
            preferences.chooseCleanupLevel(level)
            let cleaned = Language.current == .english
                ? "So I wanted to ask if we can move the meeting to Tuesday, and can you tell me who else is coming?"
                : "Also, ich wollte fragen, ob wir das Meeting am Dienstag machen können, und kannst du mir sagen, wer noch kommt?"
            tried = .init(provider: .openRouter, model: "google/gemini-3.5-flash-lite",
                          result: CleanupResult(text: cleaned, cleaned: cleaned, seconds: 0.78, dollars: 0.00019))
        }
        if provider == .ollama { tried = nil }
        // Apple's small model answered the question in the text: thrown away.
        if browsing == .apple {
            tried = .init(provider: .apple, model: CleanupCatalog.appleModel, result: CleanupResult(
                text: CleanupSample.text(for: preferences.spokenLanguage), failure: .rejected,
                cleaned: Language.current == .english ? "Tuesday works. Anna, Tom and Lena are coming." : "Dienstag passt. Es kommen Anna, Tom und Lena.",
                seconds: 1.62))
        }
        store.stage(speeds: speeds, installed: [.ollama: ["gemma4:4b", "qwen3.8:8b", "llama4:8b"]], tried: tried)
        store.looking = browsing
        return CleanupBlock(preferences: preferences, setup: Setup(hasKey: browsing == nil, microphone: .allowed, canPaste: true),
                            store: store, history: History())
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(width: 560, alignment: .leading)
            .background(Color.clear)
            .modifier(GroundBackground())
    }

    private static func setupSheet(_ step: SetupView.Step, provider: Provider = .openRouter, localModel: String? = nil,
                                   endpoint: String = "") -> some View {
        let preferences = preferences
        preferences.provider = provider
        preferences.microsoftEndpoint = endpoint
        if let localModel { preferences.localModel = localModel }
        return SetupView(
            preferences: preferences,
            setup: Setup(hasKey: step != .key || localModel != nil, microphone: .allowed, canPaste: true),
            shortcut: shortcut,
            history: History(),
            models: ModelStore(folder: nil),
            start: step,
            onDone: {}
        )
    }

    // MARK: - Local models

    /// Builds a fixed chip supports, as on an M2 to M4: the list of an M5,
    /// which Argmax does not know yet, is the same.
    private static let supported: Set<String> = [
        LocalCatalog.turbo, LocalCatalog.turboFull, LocalCatalog.turboCompatible, LocalCatalog.largeV3,
        LocalCatalog.distil, LocalCatalog.distilCompatible, LocalCatalog.small, LocalCatalog.base, LocalCatalog.tiny,
    ]

    /// Settings with Lokal in use: Parakeet V3 in use and measured, Turbo
    /// on the Mac and measured, Moonshine Base being timed after its
    /// download; among the available ones Canary downloading, the others
    /// with Argmax's estimate or their fixed score.
    private static var localSettingsSheet: some View {
        let local = LocalModels(defaults: nil)
        let measured = Date(timeIntervalSince1970: 1_791_000_000)
        let chip = Chip.current ?? "Apple M5 Pro"
        local.stage(
            states: [LocalCatalog.canary: .downloading(0.42)],
            speeds: [
                LocalCatalog.turbo: LocalSpeed(secondsPer10: 0.71, measured: measured, version: LocalModels.version, machine: chip),
                LocalCatalog.parakeetV3: LocalSpeed(secondsPer10: 0.24, measured: measured, version: LocalModels.version, machine: chip),
            ],
            supported: supported,
            onMac: [LocalCatalog.turbo, LocalCatalog.parakeetV3, LocalCatalog.moonshineBase],
            measuring: [LocalCatalog.moonshineBase]
        )
        LocalModels.shared = local
        return settingsSheet(.local)
    }

    /// Canary in use, told Spanish: its four languages under the cards.
    private static var localCanarySheet: some View {
        let local = LocalModels(defaults: nil)
        local.stage(states: [:], speeds: [:], supported: supported, onMac: [LocalCatalog.canary, LocalCatalog.turbo])
        LocalModels.shared = local
        return settingsSheet(.local, localModel: LocalCatalog.canary, toldLanguage: "es")
    }

    /// Cohere Transcribe in use, told Korean: its fourteen languages are a menu.
    private static var localCohereSheet: some View {
        let local = LocalModels(defaults: nil)
        local.stage(states: [LocalCatalog.qwen3: .downloading(0.31)], speeds: [:], supported: supported,
                    onMac: [LocalCatalog.cohere, LocalCatalog.parakeetV3])
        LocalModels.shared = local
        return settingsSheet(.local, localModel: LocalCatalog.cohere, toldLanguage: "ko")
    }

    /// Lokal looked at while OpenRouter takes the dictations: no card is
    /// active, the one that would be is first.
    private static var localBrowseSheet: some View {
        _ = localSettingsSheet
        return settingsSheet(.openRouter).environment(\.showsProvider, .local)
    }

    /// Setup, where the card is narrow: Canary in use (so its language row
    /// shows), Turbo on the Mac but never timed, the longest name failed,
    /// Small being prepared, Parakeet V3 downloading.
    private static var localSetupSheet: some View {
        let local = LocalModels(defaults: nil)
        local.stage(
            states: [LocalCatalog.turboFull: .failed("The network connection was lost."), LocalCatalog.small: .preparing,
                     LocalCatalog.parakeetV3: .downloading(0.08)],
            speeds: [:],
            supported: supported,
            onMac: [LocalCatalog.turbo, LocalCatalog.canary]
        )
        LocalModels.shared = local
        return setupSheet(.key, provider: .local, localModel: LocalCatalog.canary)
    }

}

/// True while a view is being rendered to an image rather than shown in a window.
/// Views use it to swap AppKit-backed controls, which ImageRenderer cannot draw,
/// for a static stand-in.
extension EnvironmentValues {
    @Entry var isSnapshot = false
    /// The provider Settings shows at first, for a picture of one looked at
    /// but not in use.
    @Entry var showsProvider: Provider? = nil
}

/// The window's ground behind a piece rendered on its own.
private struct GroundBackground: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background(theme.ground)
    }
}
