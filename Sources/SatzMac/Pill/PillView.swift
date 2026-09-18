import SwiftUI

/// The floating pill: the part of satz people actually see.
///
/// Always petrol, in light and dark mode alike: it floats over whatever
/// wallpaper and window happens to be behind it, and the dark brand surface
/// reads against all of them.
struct PillView: View {
    let recording: Recording
    let onCancel: () -> Void
    let onRetry: () -> Void

    private let theme = Theme.dark

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.leading, 16)
        .padding(.trailing, trailingPadding)
        .frame(height: 44)
        .background {
            Capsule(style: .continuous)
                .fill(theme.ground)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .environment(\.theme, theme)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch recording.phase {
        case .idle, .starting, .listening:
            PulsingDot(active: recording.phase == .listening)
            Waveform(levels: recording.levels)
            closeButton
        case .transcribing:
            WritingDots()
            label("Schreibt")
            closeButton
        case .clipboard:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accent)
            label("Zwischenablage")
            KeyLabel(glyph: "⌘", name: "V")
        case .failed(let message, let canRetry):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accent)
            label(message)
            if canRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.accentLabel)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.accent))
                }
                .buttonStyle(.plain)
                .help("Nochmal senden")
            }
            closeButton
        }
    }

    /// The clipboard state carries no button, so its right edge matches its left.
    private var trailingPadding: CGFloat {
        recording.phase == .clipboard ? 16 : 8
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Typography.text(14, .semibold))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
    }

    private var closeButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Abbrechen")
    }
}

/// The recording dot. Breathes while listening so the pill reads as live even
/// when nobody is speaking and the bars are flat.
private struct PulsingDot: View {
    let active: Bool
    @State private var shrunk = false

    var body: some View {
        Circle()
            .fill(Theme.light.accent)
            .frame(width: 10, height: 10)
            .scaleEffect(shrunk ? 0.72 : 1)
            .opacity(shrunk ? 0.65 : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: shrunk)
            .onAppear { shrunk = active }
            .onChange(of: active) { _, isActive in shrunk = isActive }
    }
}

/// Three dots filling in turn: working, not stuck.
private struct WritingDots: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(theme.accent.opacity(index == step ? 1 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

/// Bars driven by microphone loudness, newest on the right.
private struct Waveform: View {
    let levels: [Float]
    @Environment(\.theme) private var theme

    private let maxHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 3, height: 3 + (maxHeight - 3) * CGFloat(max(0, min(1, level))))
            }
        }
        .frame(height: maxHeight)
        // Each new level animates into place, which is what turns a row of
        // rectangles into something that reads as sound.
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}
