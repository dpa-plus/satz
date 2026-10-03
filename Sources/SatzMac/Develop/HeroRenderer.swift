import AppKit
import SwiftUI

/// Renders the repository's hero image.
///
/// It draws the real pill, so the picture in the README cannot drift away
/// from the product the way a hand-made mockup does. Regenerate with:
///
///     satz --hero assets/hero.png
@MainActor
enum HeroRenderer {

    static func write(to path: String) throws {
        try SnapshotRenderer.png(of: hero).write(to: URL(fileURLWithPath: path))
    }

    private static var hero: some View {
        let theme = Theme.dark
        return VStack(spacing: 26) {
            BrandMark(height: 56, color: theme.accent)
            Text("satz")
                .font(Typography.display(64))
                .foregroundStyle(theme.ink)
            Text("Sprechen statt Tippen.")
                .font(Typography.text(20, .medium))
                .foregroundStyle(theme.accent)
            Text("Kurzbefehl drücken, reden, nochmal drücken. Der Text steht da, wo der Cursor war.")
                .font(Typography.text(15))
                .foregroundStyle(theme.inkSecondary)
            PillView(recording: SnapshotRenderer.listening, onCancel: {}, onRetry: {})
                .padding(.top, 8)
        }
        .frame(width: 1000, height: 460)
        .background(theme.ground)
        .environment(\.theme, theme)
        .environment(\.isSnapshot, true)
    }
}
