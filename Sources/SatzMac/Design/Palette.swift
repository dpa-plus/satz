import SwiftUI

/// DPA+ brand tokens, from dpa-landing/DESIGN-CONTRACT.md.
///
/// satz is always drawn on petrol, in light and dark mode alike. The pill has to
/// read against any wallpaper, and the settings window matches it so the two
/// feel like one product rather than a floating widget plus a stock preference
/// pane. Neutrals are white at low opacity over petrol, so they stay tinted
/// toward the brand instead of going grey.
enum Palette {
    /// --o, the brand orange. For the one thing on screen that matters most.
    static let orange = Color(red: 1.0, green: 0.38, blue: 0.0)
    /// --o-dunkelflaeche, the lighter orange used on petrol surfaces.
    static let orangeOnPetrol = Color(red: 1.0, green: 0.698, blue: 0.478)
    /// --tinte, the dark petrol ground.
    static let petrol = Color(red: 0.086, green: 0.188, blue: 0.235)

    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.4)

    /// A card sitting on the petrol ground.
    static let surface = Color.white.opacity(0.045)
    /// Hairlines between rows and around cards.
    static let line = Color.white.opacity(0.08)
}
