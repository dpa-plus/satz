import AppKit
import SatzKit
import SwiftUI

/// Renders the repository's hero banner: a voice on the left streams into a
/// window where the text appears. Regenerate with `make hero`.
///
/// No model names and no timings: both change, and a banner should not.
@MainActor
enum HeroRenderer {

    static let size = CGSize(width: 1200, height: 400)

    static func write(to path: String) throws {
        let previous = Language.current
        Language.current = .english
        defer { Language.current = previous }
        let banner = StreamBanner()
        let framed = banner
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .environment(\.isSnapshot, true)
        try SnapshotRenderer.png(of: framed).write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Stream

private let ink = Color(hex: 0xF3F7F8)
private let muted = Color(hex: 0x9FB6BE)
private let orange = Color(hex: 0xFF6100)
private let peach = Color(hex: 0xFFB27A)
private let teal = Color(hex: 0x5FC4DC)

private struct StreamBanner: View {
    private let mic = CGPoint(x: 196, y: 262)
    private let window = CGRect(x: 856, y: 168, width: 292, height: 178)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x04080B), Color(hex: 0x071118), Color(hex: 0x0A1A21)],
                           startPoint: .leading, endPoint: .trailing)
            RadialGradient(colors: [orange.opacity(0.22), .clear], center: UnitPoint(x: 0.16, y: 0.66), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [teal.opacity(0.18), .clear], center: UnitPoint(x: 0.84, y: 0.64), startRadius: 0, endRadius: 320)
            DotField(color: .white, opacity: 0.045)
            Particles(from: CGPoint(x: mic.x + 46, y: mic.y), to: CGPoint(x: window.minX - 4, y: window.midY + 18))
            Microphone().position(mic)
            TextWindow().frame(width: window.width, height: window.height).position(x: window.midX, y: window.midY)
            VStack(spacing: 10) {
                Text("satz")
                    .font(Typography.display(80, .bold))
                    .foregroundStyle(ink)
                Text("Speak, and it is written where your cursor is.")
                    .font(Typography.text(22))
                    .foregroundStyle(muted)
            }
            .position(x: 548, y: 150)
        }
    }
}

/// A very faint dot grid, quieter than lines.
private struct DotField: View {
    let color: Color
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            for x in stride(from: 12.0, through: size.width, by: 24) {
                for y in stride(from: 12.0, through: size.height, by: 24) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)),
                                 with: .color(color.opacity(opacity)))
                }
            }
        }
    }
}

/// Glowing rings around a microphone, with sound arriving from the left.
private struct Microphone: View {
    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Rows of dots running in from the left edge: the voice.
                for row in -3 ... 3 {
                    let y = center.y + CGFloat(row) * 16
                    let reach = 150 - abs(CGFloat(row)) * 18
                    var x = center.x - 70
                    while x > center.x - 70 - reach {
                        let fade = (x - (center.x - 70 - reach)) / reach
                        context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)),
                                     with: .color(orange.opacity(0.15 + 0.6 * fade)))
                        x -= 12
                    }
                }
            }
            .frame(width: 400, height: 200)
            ForEach(0 ..< 4) { ring in
                Circle()
                    .strokeBorder(orange.opacity(0.5 - Double(ring) * 0.11), lineWidth: 1.2)
                    .frame(width: CGFloat(76 + ring * 30), height: CGFloat(76 + ring * 30))
            }
            Circle()
                .fill(Color(hex: 0x0D1B22))
                .frame(width: 64, height: 64)
                .overlay(Circle().strokeBorder(orange, lineWidth: 2))
                .shadow(color: orange.opacity(0.7), radius: 18)
            Image(systemName: "mic.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(peach)
        }
        .frame(width: 400, height: 200)
    }
}

/// Particles along a curve from the microphone to the window, from orange
/// to petrol-blue on the way.
private struct Particles: View {
    let from: CGPoint
    let to: CGPoint

    var body: some View {
        Canvas { context, _ in
            let c1 = CGPoint(x: from.x + 220, y: from.y + 70)
            let c2 = CGPoint(x: to.x - 260, y: to.y + 40)
            var line = Path()
            line.move(to: from)
            line.addCurve(to: to, control1: c1, control2: c2)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [orange, peach, teal]), startPoint: from, endPoint: to)
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 8))
                glow.stroke(line, with: shading, lineWidth: 6)
            }
            context.stroke(line, with: shading, lineWidth: 1.2)

            let count = 150
            for index in 0 ..< count {
                let t = Double(index) / Double(count - 1)
                let point = bezier(t, from, c1, c2, to)
                let spread = 10 * sin(t * .pi)
                let jitterX = sin(Double(index) * 12.9898) * spread
                let jitterY = sin(Double(index) * 78.233) * spread
                let radius = 0.8 + 1.8 * abs(sin(Double(index) * 3.7))
                let color = t < 0.5 ? blend(orange, peach, t * 2) : blend(peach, teal, (t - 0.5) * 2)
                context.fill(Path(ellipseIn: CGRect(x: point.x + jitterX - radius, y: point.y + jitterY - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(color.opacity(0.55 + 0.45 * sin(t * .pi))))
            }
        }
    }

    private func bezier(_ t: Double, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
            y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        )
    }

    private func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ra = NSColor(a).usingColorSpace(.sRGB)!, rb = NSColor(b).usingColorSpace(.sRGB)!
        return Color(red: ra.redComponent + (rb.redComponent - ra.redComponent) * t,
                     green: ra.greenComponent + (rb.greenComponent - ra.greenComponent) * t,
                     blue: ra.blueComponent + (rb.blueComponent - ra.blueComponent) * t)
    }
}

/// A window where the text has just landed, caret still there.
private struct TextWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                ForEach([UInt32(0xFF5F57), 0xFEBC2E, 0x28C840], id: \.self) { hex in
                    Circle().fill(Color(hex: hex).opacity(0.85)).frame(width: 10, height: 10)
                }
            }
            (Text("Thanks for the update. Thursday works for me")
                .foregroundColor(ink)
             + Text(" |").foregroundColor(orange))
                .font(Typography.text(17))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(.white.opacity(0.1)).frame(width: 200, height: 7)
                Capsule().fill(.white.opacity(0.07)).frame(width: 140, height: 7)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x0C1A21)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(teal.opacity(0.55), lineWidth: 1.2))
        .shadow(color: teal.opacity(0.35), radius: 24)
    }
}
