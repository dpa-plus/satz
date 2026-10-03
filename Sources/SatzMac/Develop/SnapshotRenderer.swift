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
        let sheets: [(String, AnyView)] = [
            ("pill", AnyView(pillSheet)),
            ("menu-light", AnyView(menuSheet.environment(\.theme, .light))),
            ("menu-dark", AnyView(menuSheet.environment(\.theme, .dark))),
            ("settings-light", AnyView(settingsSheet.environment(\.theme, .light))),
            ("settings-dark", AnyView(settingsSheet.environment(\.theme, .dark))),
            ("setup-key", AnyView(setupSheet(.key).environment(\.theme, .light))),
            ("setup-probe", AnyView(setupSheet(.probe).environment(\.theme, .light))),
        ]
        for (name, view) in sheets {
            try png(of: view.environment(\.isSnapshot, true)).write(to: folder.appendingPathComponent("\(name).png"))
        }
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
        preferences.provider = .openRouter
        preferences.words = ["ACON", "Immofanten", "Prozesshub"]
        return preferences
    }

    private static var history: History {
        let history = History()
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        history.add("Der Test ist rot, bitte nicht mergen.", app: "Slack", pasted: true, at: base)
        history.add("Termin mit ACON auf Donnerstag 14 Uhr verschieben.", app: "Mail", pasted: true, at: base + 600)
        history.add("Kannst du mir eine Funktion schreiben, die alle Rechnungen aus dem Ordner Buchhaltung liest und die Beträge pro Kunde summiert?",
                    app: "Claude", pasted: true, at: base + 1200)
        return history
    }

    private static var shortcut: Shortcut {
        Shortcut(preferences: preferences, onPress: {}, onRelease: {})
    }

    // MARK: - Sheets

    private static var pillSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            PillView(recording: listening, onCancel: {}, onRetry: {})
            PillView(recording: transcribing, onCancel: {}, onRetry: {})
            PillView(recording: clipboard, onCancel: {}, onRetry: {})
            PillView(recording: failed, onCancel: {}, onRetry: {})
        }
        .padding(28)
        .background(Color(hex: 0xE9DDD2))
    }

    private static var menuSheet: some View {
        HStack(alignment: .top, spacing: 24) {
            PopoverView(history: history, outbox: Outbox(), setup: Setup(hasKey: true, microphone: .allowed, canPaste: true),
                        shortcut: shortcut, preferences: preferences, actions: PopoverActions())
            PopoverView(history: History(), outbox: Outbox(), setup: Setup(hasKey: true, microphone: .allowed, canPaste: true),
                        shortcut: shortcut, preferences: preferences, actions: PopoverActions())
            PopoverView(history: history,
                        outbox: Outbox(pending: .init(audio: Data(count: 44 + 23 * 32_000), origin: nil, reason: "Keine Verbindung")),
                        setup: Setup(hasKey: true, microphone: .allowed, canPaste: true),
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

    // MARK: - Pill states

    static var listening: Recording {
        let recording = Recording()
        recording.listening()
        // A plausible speech envelope rather than a flat line.
        for level in [0.1, 0.3, 0.55, 0.8, 0.62, 0.35, 0.5, 0.75, 0.9, 0.6, 0.3, 0.45, 0.7, 0.4] {
            recording.push(level: Float(level))
        }
        return recording
    }

    private static var transcribing: Recording {
        let recording = Recording()
        recording.listening()
        recording.transcribing()
        return recording
    }

    private static var clipboard: Recording {
        let recording = Recording()
        recording.clipboard()
        return recording
    }

    private static var failed: Recording {
        let recording = Recording()
        recording.listening()
        recording.fail("Keine Verbindung", canRetry: true)
        return recording
    }
}

/// True while a view is being rendered to an image rather than shown in a window.
/// Views use it to swap AppKit-backed controls, which ImageRenderer cannot draw,
/// for a static stand-in.
extension EnvironmentValues {
    @Entry var isSnapshot = false
}
