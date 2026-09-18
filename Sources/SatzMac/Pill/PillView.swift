import SwiftUI

/// The floating pill: a recording dot, a live waveform, and a way out.
struct PillView: View {
    let recording: Recording
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            indicator
            content
            cancelButton
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background {
            Capsule(style: .continuous)
                .fill(Palette.petrol)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var indicator: some View {
        switch recording.phase {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.orangeOnPetrol)
        default:
            PulsingDot(active: recording.phase == .listening)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch recording.phase {
        case .listening, .idle:
            Waveform(levels: recording.levels)
        case .transcribing:
            Text("Schreibt …")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 96, alignment: .leading)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
        }
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 20, height: 20)
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
            .fill(Palette.orange)
            .frame(width: 10, height: 10)
            .scaleEffect(shrunk ? 0.72 : 1)
            .opacity(shrunk ? 0.65 : 1)
            .animation(
                active
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: shrunk
            )
            .onAppear { shrunk = active }
            .onChange(of: active) { _, isActive in shrunk = isActive }
    }
}

/// Bars driven by microphone loudness, newest on the right.
private struct Waveform: View {
    let levels: [Float]

    private let barWidth: CGFloat = 3
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Palette.orangeOnPetrol)
                    .frame(width: barWidth, height: height(for: level))
            }
        }
        .frame(height: maxHeight)
        // Each new level animates into place, which is what turns a row of
        // rectangles into something that reads as sound.
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func height(for level: Float) -> CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(max(0, min(1, level)))
    }
}
