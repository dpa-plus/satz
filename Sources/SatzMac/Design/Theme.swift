import SatzKit
import SwiftUI

/// Colour tokens for one appearance, light or dark, of one colour family.
///
/// The DPA+ family comes from dpa-landing/DESIGN.md. The website is sand only;
/// a menu bar tool cannot be: a sand panel under a dark menu bar looks broken.
/// So light mode is the pale ground with ink, dark mode the family's deep
/// surface, and every value has a pair.
///
/// Contrast rules every family follows: secondary text passes AA on its
/// ground, and the label on an accent button passes on that accent (ink on
/// DPA+ orange, because white on #ff6100 is 3.0:1).
struct Theme {
    /// The window or panel itself.
    let ground: Color
    let ink: Color
    /// Secondary text on the ground.
    let inkSecondary: Color
    /// Secondary text on a card, where a lighter grey still passes.
    let inkOnCard: Color
    let card: Color
    let cardBorder: Color
    /// Outlines of buttons and fields, strong enough to read as controls (3:1).
    let control: Color
    let hairline: Color
    let hover: Color
    let accent: Color
    let accentShadow: Color
    /// The label colour on `accent`.
    let accentLabel: Color
    /// A stronger accent for a filled button on the dark card (the
    /// recording microphone), labelled with the dark ground colour.
    let signal: Color

    /// The current family's light and dark appearance.
    static var light: Theme { AppTheme.current.light }
    static var dark: Theme { AppTheme.current.dark }

    static func `for`(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }

    /// A light appearance from a family's few base colours.
    fileprivate static func light(ground: UInt32, ink: UInt32, secondary: UInt32, onCard: UInt32,
                                  accent: UInt32, accentLabel: UInt32, signal: UInt32) -> Theme {
        Theme(
            ground: Color(hex: ground), ink: Color(hex: ink), inkSecondary: Color(hex: secondary),
            inkOnCard: Color(hex: onCard), card: .white, cardBorder: Color(hex: ink),
            control: Color(hex: ink).opacity(0.55), hairline: Color(hex: ink).opacity(0.12),
            hover: Color(hex: ink).opacity(0.07), accent: Color(hex: accent),
            accentShadow: Color(hex: ink).opacity(0.28), accentLabel: Color(hex: accentLabel), signal: Color(hex: signal)
        )
    }

    /// A dark appearance from a family's few base colours.
    fileprivate static func dark(ground: UInt32, ink: UInt32, secondary: UInt32, accent: UInt32, signal: UInt32) -> Theme {
        Theme(
            ground: Color(hex: ground), ink: Color(hex: ink), inkSecondary: Color(hex: secondary),
            inkOnCard: Color(hex: secondary), card: Color(hex: ink).opacity(0.06), cardBorder: Color(hex: ink).opacity(0.4),
            control: Color(hex: ink).opacity(0.4), hairline: Color(hex: ink).opacity(0.12),
            hover: Color(hex: ink).opacity(0.08), accent: Color(hex: accent),
            accentShadow: Color.black.opacity(0.35), accentLabel: Color(hex: ground), signal: Color(hex: signal)
        )
    }
}

/// The colour families to choose from in Settings. DPA+ is the default.
enum AppTheme: String, CaseIterable, Codable, Sendable {
    case dpa
    case forest
    case lavender
    case sky

    /// Set by the app from its preference; read by every view.
    nonisolated(unsafe) static var current: AppTheme = .dpa

    var name: String {
        switch self {
        case .dpa: "DPA+"
        case .forest: de("Wald", en: "Forest")
        case .lavender: de("Lavendel", en: "Lavender")
        case .sky: de("Hellblau", en: "Light blue")
        }
    }

    var light: Theme {
        switch self {
        case .dpa:
            // Sand, petrol ink, orange. Secondary text is #40545c, not the
            // website's #5d7078, which fails AA on sand.
            Theme(
                ground: Color(hex: 0xFFEADE), ink: Color(hex: 0x16303C), inkSecondary: Color(hex: 0x40545C),
                inkOnCard: Color(hex: 0x5D7078), card: .white, cardBorder: Color(hex: 0x16303C),
                control: Color(hex: 0x16303C).opacity(0.55), hairline: Color(hex: 0x16303C).opacity(0.12),
                hover: Color(hex: 0x16303C).opacity(0.07), accent: Color(hex: 0xFF6100),
                accentShadow: Color(red: 180 / 255, green: 66 / 255, blue: 0).opacity(0.28),
                accentLabel: Color(hex: 0x16303C), signal: Color(hex: 0xFF6100)
            )
        case .forest:
            .light(ground: 0xEDF3EC, ink: 0x1E3A2B, secondary: 0x3E5A4A, onCard: 0x56705F,
                   accent: 0x2E7D4F, accentLabel: 0xFFFFFF, signal: 0x3FA066)
        case .lavender:
            .light(ground: 0xF3EFFA, ink: 0x2E2445, secondary: 0x54496B, onCard: 0x6B6182,
                   accent: 0x7454BE, accentLabel: 0xFFFFFF, signal: 0x9B7BE3)
        case .sky:
            .light(ground: 0xEAF4FB, ink: 0x12324A, secondary: 0x3D5A70, onCard: 0x557086,
                   accent: 0x1F74AE, accentLabel: 0xFFFFFF, signal: 0x3FA9E0)
        }
    }

    var dark: Theme {
        switch self {
        case .dpa:
            .dark(ground: 0x16303C, ink: 0xEEF4F6, secondary: 0xA9C0C8, accent: 0xFFB27A, signal: 0xFF6100)
        case .forest:
            .dark(ground: 0x15281E, ink: 0xE8F1EA, secondary: 0xA7C2B0, accent: 0x8AD6A4, signal: 0x3FA066)
        case .lavender:
            .dark(ground: 0x241D36, ink: 0xEEEAF7, secondary: 0xB7AED0, accent: 0xC6B4F2, signal: 0x9B7BE3)
        case .sky:
            .dark(ground: 0x10283A, ink: 0xE8F2F9, secondary: 0xA6C1D3, accent: 0x93CEF2, signal: 0x3FA9E0)
        }
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
