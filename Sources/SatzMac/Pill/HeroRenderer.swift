import AppKit
import SwiftUI

/// Renders the repository's hero image.
///
/// It draws the real `PillView`, so the picture in the README cannot drift away
/// from the product the way a hand-made mockup does. Regenerate with:
///
///     satz --hero assets/hero.png
@MainActor
enum HeroRenderer {

    static func write(to path: String) throws {
        let renderer = ImageRenderer(content: hero)
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

    private static var hero: some View {
        VStack(spacing: 26) {
            mark
            Text("satz")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Sprechen statt Tippen.")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.orangeOnPetrol)
            Text("Taste drücken, reden, loslassen. Der Text steht da, wo der Cursor war.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
            PillView(recording: listening, onCancel: {})
                .padding(.top, 8)
        }
        .frame(width: 1000, height: 460)
        .background(Palette.petrol)
    }

    /// The logo mark: the waveform on its own, which is the one form that stays
    /// legible at menu bar size.
    private static var mark: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach([0.30, 0.55, 0.80, 1.00, 0.80, 0.55, 0.30], id: \.self) { scale in
                Capsule()
                    .fill(Palette.orange)
                    .frame(width: 8, height: 14 + 40 * scale)
            }
        }
        .frame(height: 56)
    }

    private static var listening: Recording {
        let recording = Recording()
        recording.listening()
        for level in [0.1, 0.3, 0.55, 0.8, 0.62, 0.35, 0.5, 0.75, 0.9, 0.6, 0.3, 0.45, 0.7, 0.4] {
            recording.push(level: Float(level))
        }
        return recording
    }
}
