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
            ("setup-key", .german, { AnyView(setupSheet(.key).environment(\.theme, .light)) }),
            ("setup-probe", .german, { AnyView(setupSheet(.probe).environment(\.theme, .light)) }),
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
        let icons = HStack(spacing: 24) {
            ForEach(AppTheme.allCases, id: \.self) { family in
                IconRenderer.tile(for: family).scaleEffect(0.18).frame(width: 184, height: 184)
            }
        }
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

    private static var shortcut: Shortcut {
        Shortcut(preferences: preferences, onPress: {}, onRelease: {})
    }

    // MARK: - Sheets

    private static let speech: [Float] = [0.1, 0.3, 0.55, 0.8, 0.62, 0.35, 0.5, 0.75, 0.9, 0.6, 0.3, 0.45]

    private static func card(_ phase: Session.Phase, text: String = "", marker: Bool = false) -> some View {
        let session = Session(preferences: preferences, history: History(), discarded: Discarded())
        session.stage(phase, text: text, marker: marker, levels: phase == .listening ? speech : [])
        return CardView(session: session, preferences: preferences)
    }

    private static var cardSheet: some View {
        let text = "Schreib mir eine Funktion, die alle Rechnungen aus dem Ordner liest. Dann soll sie die Beträge summieren."
        return VStack(spacing: 22) {
            card(.listening, marker: true)
            card(.listening, text: text + " ", marker: true)
            card(.paused, text: text)
            card(.finishing, text: text)
            card(.failed("Keine Verbindung", canRetry: true), text: text)
            card(.discarded)
            card(.clipboard)
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

    private static var settingsSheet: some View {
        SettingsView(
            preferences: preferences,
            setup: Setup(hasKey: true, microphone: .allowed, canPaste: true),
            shortcut: shortcut,
            launchAtLogin: LaunchAtLogin(),
            history: history
        )
    }

    private static func setupSheet(_ step: SetupView.Step) -> some View {
        SetupView(
            preferences: preferences,
            setup: Setup(hasKey: step != .key, microphone: .allowed, canPaste: true),
            shortcut: shortcut,
            history: History(),
            start: step,
            onDone: {}
        )
    }

}

/// True while a view is being rendered to an image rather than shown in a window.
/// Views use it to swap AppKit-backed controls, which ImageRenderer cannot draw,
/// for a static stand-in.
extension EnvironmentValues {
    @Entry var isSnapshot = false
}
