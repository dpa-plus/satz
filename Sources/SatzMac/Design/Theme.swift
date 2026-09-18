import SwiftUI

/// DPA+ brand tokens, from dpa-landing/DESIGN.md, resolved for the Mac's
/// appearance.
///
/// The website is sand only. A menu bar tool cannot be: a sand panel under a
/// dark menu bar looks broken. So light mode is sand and ink, dark mode is the
/// brand's own petrol surface, and every value below has a pair.
///
/// Two deliberate departures from the website, both for contrast:
/// labels on orange are ink, not white (white on #ff6100 is 3.0:1), and
/// secondary text on sand is #40545c, not #5d7078 (4.46:1 fails AA).
struct Theme {
    /// The window or panel itself.
    let ground: Color
    let ink: Color
    /// Secondary text on the ground.
    let inkSecondary: Color
    /// Secondary text on a card, where the lighter grey still passes.
    let inkOnCard: Color
    let card: Color
    let cardBorder: Color
    /// Outlines of buttons and fields, strong enough to read as controls (3:1).
    let control: Color
    let hairline: Color
    let hover: Color
    let accent: Color
    let accentShadow: Color
    /// Always ink: it is the only label colour that passes on both oranges.
    let accentLabel = Color(hex: 0x16303C)

    static let light = Theme(
        ground: Color(hex: 0xFFEADE),
        ink: Color(hex: 0x16303C),
        inkSecondary: Color(hex: 0x40545C),
        inkOnCard: Color(hex: 0x5D7078),
        card: .white,
        cardBorder: Color(hex: 0x16303C),
        control: Color(hex: 0x16303C).opacity(0.55),
        hairline: Color(hex: 0x16303C).opacity(0.12),
        hover: Color(hex: 0x16303C).opacity(0.07),
        accent: Color(hex: 0xFF6100),
        accentShadow: Color(red: 180 / 255, green: 66 / 255, blue: 0).opacity(0.28)
    )

    static let dark = Theme(
        ground: Color(hex: 0x16303C),
        ink: Color(hex: 0xEEF4F6),
        inkSecondary: Color(hex: 0xA9C0C8),
        inkOnCard: Color(hex: 0xA9C0C8),
        card: Color(hex: 0xEEF4F6).opacity(0.06),
        cardBorder: Color(hex: 0xEEF4F6).opacity(0.4),
        control: Color(hex: 0xEEF4F6).opacity(0.4),
        hairline: Color(hex: 0xEEF4F6).opacity(0.12),
        hover: Color(hex: 0xEEF4F6).opacity(0.08),
        accent: Color(hex: 0xFFB27A),
        accentShadow: Color(red: 180 / 255, green: 66 / 255, blue: 0).opacity(0.35)
    )

    static func `for`(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .light
}

extension View {
    /// Resolves the theme from the current appearance. Apply once at the root
    /// of each window; everything inside reads `@Environment(\.theme)`.
    func themed() -> some View {
        modifier(Themed())
    }
}

private struct Themed: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.theme, .for(scheme))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
