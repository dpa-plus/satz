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
        try SnapshotRenderer.png(of: hero).write(to: URL(fileURLWithPath: path))
    }

    private static var hero: some View {
        VStack(spacing: 26) {
            WaveformMark(height: 56)
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

    private static var listening: Recording { SnapshotRenderer.listening }
}
