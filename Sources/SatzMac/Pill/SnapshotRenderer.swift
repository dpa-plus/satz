import AppKit
import SwiftUI

/// Renders the pill straight to a PNG, without ever putting a window on screen.
///
/// `satz --snapshot <path>` is how the pill gets looked at during development:
/// no floating window stealing the desktop, no screen recording permission, and
/// it captures every state in one sheet rather than only whichever one happens
/// to be live. Also the obvious hook for a visual check in CI later.
@MainActor
enum SnapshotRenderer {

    static func write(to path: String) throws {
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2

        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    private static var sheet: some View {
        VStack(alignment: .leading, spacing: 20) {
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

    private static var listening: Recording {
        let recording = Recording()
        recording.begin()
        // A plausible speech envelope rather than a flat line, so the snapshot
        // shows what the bars actually look like mid-sentence.
        for level in [0.1, 0.3, 0.55, 0.8, 0.62, 0.35, 0.5, 0.75, 0.9, 0.6, 0.3, 0.45, 0.7, 0.4] {
            recording.push(level: Float(level))
        }
        return recording
    }

    private static var transcribing: Recording {
        let recording = Recording()
        recording.begin()
        recording.transcribing()
        return recording
    }

    private static var failed: Recording {
        let recording = Recording()
        recording.begin()
        recording.fail("Keine Verbindung zu OpenAI.")
        return recording
    }
}
