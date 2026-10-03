import AppKit
import SwiftUI

/// Renders the repository's hero image.
///
/// It draws the real card, so the picture in the README cannot drift away
/// from the product the way a hand-made mockup does. Regenerate with:
///
///     satz --hero assets/hero.png
@MainActor
enum HeroRenderer {

    static func write(to path: String) throws {
        try SnapshotRenderer.png(of: hero).write(to: URL(fileURLWithPath: path))
    }

    private static var card: Session {
        let session = Session(preferences: Preferences(defaults: nil), history: History(), discarded: Discarded())
        session.stage(.listening, text: "Kurzbefehl drücken, reden, nochmal drücken. ", marker: true,
                      levels: [0.1, 0.3, 0.55, 0.8, 0.62, 0.35, 0.5, 0.75, 0.9, 0.6, 0.3, 0.45])
        return session
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
            CardView(session: card, preferences: Preferences(defaults: nil))
                .padding(.top, 8)
        }
        .frame(width: 1000, height: 480)
        .background(theme.ground)
        .environment(\.theme, theme)
        .environment(\.isSnapshot, true)
    }
}
