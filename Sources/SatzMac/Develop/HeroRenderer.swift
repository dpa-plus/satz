import AppKit
import SatzKit
import SwiftUI

/// Renders the repository's hero banner: a sound wave flowing into the real
/// satz card, in the dark style of the other DPA+ repositories.
///
/// It draws the actual `CardView`, so the picture cannot drift away from the
/// product the way a hand-made mockup does. Regenerate with `make hero`.
@MainActor
enum HeroRenderer {

    static let size = CGSize(width: 1200, height: 400)

    static func write(to path: String) throws {
        let previous = Language.current
        Language.current = .english
        defer { Language.current = previous }
        try SnapshotRenderer.png(of: banner).write(to: URL(fileURLWithPath: path))
    }

    private static var banner: some View {
        ZStack(alignment: .topLeading) {
            Backdrop()
            SoundStream()
            Headline()
                .padding(.leading, 72)
                .padding(.top, 74)
            card
                .scaleEffect(1.3, anchor: .center)
                .shadow(color: Color(hex: 0xFF6100).opacity(0.22), radius: 40)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                .position(x: 922, y: 214)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
        .environment(\.isSnapshot, true)
    }

    private static var card: some View {
        let preferences = Preferences(defaults: nil)
        preferences.showsText = true
        let session = Session(preferences: preferences, history: History(), discarded: Discarded())
        session.stage(.listening,
                      text: "Thanks for the update. Thursday at two works for me, I'll bring the numbers. ",
                      marker: true,
                      levels: [0.2, 0.45, 0.7, 0.95, 0.75, 0.4, 0.6, 0.85, 1, 0.65, 0.35, 0.5])
        return CardView(session: session, preferences: preferences)
            .environment(\.isSnapshot, true)
    }
}

/// Deep petrol-black with an orange glow behind the title, a petrol glow
/// behind the card, and a faint grid.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x05090C), Color(hex: 0x0A151B), Color(hex: 0x0E2129)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(colors: [Color(hex: 0xFF6100).opacity(0.34), Color(hex: 0xFF6100).opacity(0.08), .clear],
                           center: UnitPoint(x: 0.2, y: 0.12), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Color(hex: 0x2B7A92).opacity(0.42), Color(hex: 0x16303C).opacity(0.18), .clear],
                           center: UnitPoint(x: 0.77, y: 0.5), startRadius: 0, endRadius: 460)
            Canvas { context, size in
                var grid = Path()
                stride(from: 0, through: size.width, by: 40).forEach { x in
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: 0, through: size.height, by: 40).forEach { y in
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.03)), lineWidth: 1)
            }
        }
    }
}

/// Speech coming in from the left as bars, thinning into a glowing line
/// that runs into the card's microphone.
private struct SoundStream: View {
    var body: some View {
        Canvas { context, size in
            // The line the sound travels along, ending at the card's mic button.
            let start = CGPoint(x: 0, y: 340)
            let end = CGPoint(x: 712, y: 262)
            var line = Path()
            line.move(to: start)
            line.addCurve(to: end, control1: CGPoint(x: 280, y: 382), control2: CGPoint(x: 500, y: 250))
            let gradient = Gradient(colors: [Color(hex: 0xFF6100).opacity(0), Color(hex: 0xFF6100), Color(hex: 0xFFB27A)])
            let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: start, endPoint: end)
            // The glow on a layer of its own, so its blur stays off the bars.
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 7))
                glow.stroke(line, with: shading, lineWidth: 7)
            }
            context.stroke(line, with: shading, lineWidth: 2)

            // Bars along the start of the line, loud in the middle, fading out.
            let bars = 34
            for index in 0 ..< bars {
                let t = Double(index) / Double(bars - 1)
                let point = bezier(t * 0.55, start, CGPoint(x: 280, y: 382), CGPoint(x: 500, y: 250), end)
                let envelope = sin(t * .pi) * (0.55 + 0.45 * abs(sin(t * 19)))
                let height = 5 + 46 * envelope
                let bar = Path(roundedRect: CGRect(x: point.x - 2, y: point.y - height / 2, width: 4, height: height),
                               cornerRadius: 2)
                let color = t < 0.5 ? Color(hex: 0xFF6100) : Color(hex: 0xFFB27A)
                context.fill(bar, with: .color(color.opacity(0.25 + 0.6 * envelope)))
            }
        }
        .frame(width: HeroRenderer.size.width, height: HeroRenderer.size.height)
    }

    private func bezier(_ t: Double, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }
}

private struct Headline: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DICTATION FOR MACOS")
                .font(Typography.mono(14, .medium))
                .tracking(2)
                .foregroundStyle(Color(hex: 0xFFB27A))
                .padding(.bottom, 10)
            HStack(alignment: .center, spacing: 18) {
                BrandMark(height: 52, color: Color(hex: 0xFF6100))
                Text("satz")
                    .font(Typography.display(92, .bold))
                    .foregroundStyle(Color(hex: 0xF3F7F8))
            }
            Text("Talk anywhere. It lands at your cursor.")
                .font(Typography.text(23))
                .foregroundStyle(Color(hex: 0xA9C0C8))
                .padding(.top, 2)
            HStack(spacing: 12) {
                Chip(text: "MAI-Transcribe 2", color: Color(hex: 0xFF8A3D))
                Chip(text: "clean mode", color: Color(hex: 0xFFB27A))
                Chip(text: "~1 s to text", color: Color(hex: 0x6FC3D8))
            }
            .padding(.top, 26)
        }
    }
}

private struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Typography.mono(14, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .frame(height: 36)
            // Solid, so the sound stream passes behind it cleanly.
            .background(Capsule().fill(Color(hex: 0x0B141A)))
            .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
    }
}
