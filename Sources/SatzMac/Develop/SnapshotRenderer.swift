import AppKit
import SwiftUI

/// Renders satz's surfaces straight to PNGs, without ever putting a window on
/// screen.
///
/// `satz --snapshot <directory>` writes `pill.png` with every pill state and
/// `settings.png` with the settings window in a half set-up state. This is how
/// the interface gets looked at during development: no window stealing the
/// desktop, no screen recording permission, and every state at once rather
/// than whichever one happens to be live. CI renders it too.
@MainActor
enum SnapshotRenderer {

    static func write(to directory: String) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png(of: pillSheet).write(to: folder.appendingPathComponent("pill.png"))
        try png(of: settingsSheet).write(to: folder.appendingPathComponent("settings.png"))
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

    // MARK: - Pill

    private static var pillSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            row("Mikrofon", PillView(recording: starting, onCancel: {}))
            row("aufnehmen", PillView(recording: listening, onCancel: {}))
            row("übertragen", PillView(recording: transcribing, onCancel: {}))
            row("Fehler", PillView(recording: failed, onCancel: {}))
        }
        .padding(28)
        .background(Color(white: 0.9))
    }

    private static func row(_ label: String, _ pill: some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.black.opacity(0.45))
            pill
        }
    }

    static var listening: Recording {
        let recording = Recording()
        recording.listening()
        // A plausible speech envelope rather than a flat line, so the snapshot
        // shows what the bars actually look like mid-sentence.
        for level in [0.1, 0.3, 0.55, 0.8, 0.62, 0.35, 0.5, 0.75, 0.9, 0.6, 0.3, 0.45, 0.7, 0.4] {
            recording.push(level: Float(level))
        }
        return recording
    }

    private static var starting: Recording {
        let recording = Recording()
        recording.starting()
        return recording
    }

    private static var transcribing: Recording {
        let recording = Recording()
        recording.listening()
        recording.transcribing()
        return recording
    }

    private static var failed: Recording {
        let recording = Recording()
        recording.listening()
        recording.fail("Keine Verbindung zum Anbieter.")
        return recording
    }

    // MARK: - Settings

    /// Half set up on purpose, so one picture shows both a finished row and a
    /// row asking for action.
    private static var settingsSheet: some View {
        let history = History()
        history.add("Bitte schick mir die Unterlagen bis Freitag, dann schaue ich sie mir am Wochenende an.",
                    at: Date(timeIntervalSince1970: 1_789_300_000))
        history.add("Termin mit ACON auf Donnerstag 14 Uhr verschieben.",
                    at: Date(timeIntervalSince1970: 1_789_303_600))

        // In memory: a snapshot must never write to the user's preferences.
        let preferences = Preferences(defaults: nil)
        preferences.provider = .openRouter
        preferences.vocabulary = "ACON, Immofanten, Prozesshub, DPA Plus"

        return SettingsContent(
            setup: Setup(hasKey: true, microphone: .allowed, canPaste: false),
            preferences: preferences,
            history: history,
            probe: Probe(state: .heard("Das ist ein Test, eins, zwei, drei."))
        )
        .background(Palette.petrol)
        .environment(\.colorScheme, .dark)
        .environment(\.isSnapshot, true)
    }
}

/// True while a view is being rendered to an image rather than shown in a window.
/// Views use it to swap AppKit-backed controls, which ImageRenderer cannot draw,
/// for a static stand-in.
extension EnvironmentValues {
    @Entry var isSnapshot = false
}
