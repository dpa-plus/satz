import SwiftUI
import SatzKit

/// The pill and its text, as one card. The text grows upward from the strip;
/// the strip's buttons never move.
///
/// Always petrol, in light and dark mode alike: it floats over whatever is
/// behind it, and the dark brand surface reads against all of it.
struct CardView: View {
    let session: Session
    @Bindable var preferences: Preferences
    var onSize: (CGSize) -> Void = { _ in }
    /// Dragging the strip moves the card: true while the drag goes on,
    /// false once it ends.
    var onDrag: (Bool) -> Void = { _ in }

    @Environment(\.isSnapshot) private var isSnapshot
    @State private var textHeight: CGFloat = 0
    private let theme = Theme.dark

    /// About five lines, then the text scrolls inside the card.
    static let maxTextHeight: CGFloat = 5 * 20 + CardTextView.inset.height * 2
    static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            if showsText {
                Group {
                    if isSnapshot {
                        SnapshotText(session: session)
                    } else {
                        CardTextView(session: session, height: $textHeight)
                            .frame(height: min(max(textHeight, 36), Self.maxTextHeight))
                    }
                }
                Rectangle().fill(theme.hairline).frame(height: 1)
            }
            Strip(session: session, preferences: preferences, onDrag: onDrag)
        }
        .id(preferences.language)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.ground))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .environment(\.theme, theme)
        .focusEffectDisabled()
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSize)
    }

    /// Only once there is text: the placeholder alone is not worth a line.
    private var showsText: Bool {
        guard preferences.showsText, session.hasRealText else { return false }
        switch session.phase {
        case .idle, .discarded, .clipboard: return false
        default: return true
        }
    }
}

// MARK: - Strip

/// Microphone on the left, eye and × on the right, always in the same place.
/// Only the middle changes with the state.
private struct Strip: View {
    let session: Session
    @Bindable var preferences: Preferences
    let onDrag: (Bool) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            microphone
            middle
            Spacer(minLength: 0)
            eye
            close
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        // The whole strip is the handle, waveform and labels included; a
        // plain click on a button still goes to the button.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in onDrag(true) }
                .onEnded { _ in onDrag(false) }
        )
    }

    @ViewBuilder
    private var middle: some View {
        switch session.phase {
        case .idle, .starting, .listening, .paused:
            Waveform(levels: session.levels, live: session.phase == .listening)
            // While listening the moving bars say it; only a pause gets a word.
            if session.phase == .paused { label(de("Pausiert", en: "Paused")) }
            if !session.inFlight.isEmpty { WritingDots() }
        case .finishing:
            WritingDots()
            label(de("Schreibt", en: "Writing"))
        case .failed(let message, let canRetry):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
            label(message)
            if canRetry {
                Button(de("Nochmal", en: "Retry"), action: session.retry)
                    .buttonStyle(.plain)
                    .font(Typography.text(13, .semibold))
                    .foregroundStyle(theme.accentLabel)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(theme.accent))
            }
        case .discarded:
            label(de("Verworfen", en: "Discarded"))
            Button(action: session.undoDiscard) {
                Text(de("Rückgängig", en: "Undo")).underline()
            }
            .buttonStyle(.plain)
            .font(Typography.text(13, .semibold))
            .foregroundStyle(theme.accent)
        case .clipboard:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
            label(de("Zwischenablage", en: "Clipboard"))
            KeyLabel(glyph: "⌘", name: "V")
        }
    }

    private var microphone: some View {
        let listening = session.phase == .listening
        let usable = listening || session.phase == .paused
        return Button(action: session.toggleMicrophone) {
            Image(systemName: listening ? "pause.fill" : "mic.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(listening ? theme.accentLabel : usable ? theme.accent : theme.inkSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(listening ? Theme.light.accent : .white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .help(listening ? de("Pause", en: "Pause") : de("Weitersprechen", en: "Continue"))
    }

    private var eye: some View {
        Button { preferences.showsText.toggle() } label: {
            Image(systemName: preferences.showsText ? "eye" : "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.inkSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preferences.showsText ? de("Text ausblenden", en: "Hide text") : de("Text zeigen", en: "Show text"))
    }

    private var close: some View {
        Button(action: session.discard) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.ink)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(de("Verwerfen", en: "Discard"))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Typography.text(12, .medium))
            .foregroundStyle(theme.inkSecondary)
            .lineLimit(1)
    }
}

// MARK: - Pieces

/// Bars driven by microphone loudness, newest on the right. Flat and dimmed
/// while paused.
struct Waveform: View {
    let levels: [Float]
    var live = true
    @Environment(\.theme) private var theme

    private let maxHeight: CGFloat = 16

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(theme.accent.opacity(live ? 1 : 0.45))
                    .frame(width: 2.5, height: 2.5 + (maxHeight - 2.5) * CGFloat(max(0, min(1, level))))
            }
        }
        .frame(height: maxHeight)
        // Each new level animates into place, which is what turns a row of
        // rectangles into something that reads as sound.
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// Three dots filling in turn: working, not stuck.
struct WritingDots: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 5) {
                ForEach(0 ..< 3) { index in
                    Circle()
                        .fill(theme.accent.opacity(index == step ? 1 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

/// ImageRenderer cannot draw an NSTextView, so snapshots draw the text with
/// SwiftUI instead.
private struct SnapshotText: View {
    let session: Session
    @Environment(\.theme) private var theme

    var body: some View {
        composed
            .font(Typography.text(14))
            .foregroundStyle(theme.ink)
            .lineSpacing(3)
            .padding(.horizontal, CardTextView.inset.width + 5)
            .padding(.vertical, CardTextView.inset.height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The text with its placeholders in orange.
    private var composed: Text {
        var result = Text("")
        let string = session.text.string as NSString
        session.text.enumerateAttribute(.satzMarker, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            let piece = Text(string.substring(with: range))
            result = result + (value == nil ? piece : piece.foregroundColor(theme.accent))
        }
        return result
    }
}
