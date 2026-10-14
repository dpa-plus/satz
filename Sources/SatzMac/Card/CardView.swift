import SwiftUI
import SatzKit

/// The pill and its text, as one card: the text on top, and under it one row
/// with the waveform filling the space up to the buttons at the right. The
/// text grows upward and the card widens and narrows from its right edge, so
/// the buttons never move from under the mouse.
///
/// Always petrol, in light and dark mode alike: it floats over whatever is
/// behind it, and the dark brand surface reads against all of it.
struct CardView: View {
    let session: Session
    @Bindable var preferences: Preferences
    /// Dragging the strip moves the card: true while the drag goes on,
    /// false once it ends.
    var onDrag: (Bool) -> Void = { _ in }

    @Environment(\.isSnapshot) private var isSnapshot
    /// Read on every draw, so a newly picked colour shows at once.
    private var theme: Theme { Look.shared.family.dark }

    /// About five lines, then the text scrolls inside the card.
    static let maxTextHeight: CGFloat = 5 * 20 + CardTextView.inset.height * 2
    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            if canHoldText {
                // Always there while dictating, folded to nothing when hidden,
                // so showing and hiding is one smooth change of height
                // instead of a view appearing and disappearing.
                //
                // The text itself is always laid out at the full card width
                // and pinned to the card's bottom right, and the card's edges
                // only uncover it. Text that rewrapped at every step of the
                // card widening jumped from line to line.
                let height = CardTextView.height(of: session.text, version: session.textVersion)
                Color.clear
                    .frame(height: showsText ? height : 0)
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            if isSnapshot {
                                SnapshotText(session: session)
                            } else {
                                CardTextView(session: session, version: session.textVersion)
                            }
                        }
                        .frame(width: Self.width, height: height)
                    }
                    .clipped()
                    .opacity(showsText ? 1 : 0)
                // Above the line: text to click and select. Below: the handle.
                Rectangle().fill(theme.hairline)
                    .frame(height: showsText ? 1 : 0)
            }
            Strip(session: session, preferences: preferences, wide: showsText, onDrag: onDrag)
        }
        .id(preferences.lookKey)
        // Full width with text, a fixed small width as a pill, so the width
        // always has a number to animate between.
        .frame(width: width)
        .fixedSize(horizontal: width == nil, vertical: true)
        // Nothing inside, text included, ever shows outside the card's shape,
        // not even halfway through a resize.
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(GlassSurface(cornerRadius: 18, tint: theme.ground, snapshot: isSnapshot))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .animation(.smooth(duration: 0.32), value: showsText)
        .animation(.smooth(duration: 0.22), value: session.textVersion)
        .environment(\.theme, theme)
        .focusEffectDisabled()
        .onChange(of: Look.shared.family) { session.recolor() }
        // In the bottom right corner of a window that never changes size, so
        // the card animates on its own and the buttons stay put.
        .padding(CardPanel.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// The pill's width: room for the short wave and the three buttons.
    static let pillWidth: CGFloat = 200

    private var width: CGFloat? {
        if showsText { return Self.width }
        switch session.phase {
        case .idle, .starting, .listening, .paused: return Self.pillWidth
        // Short status lines ("Verworfen · Rückgängig") take what they need.
        default: return nil
        }
    }

    /// Phases in which the card can show text at all.
    private var canHoldText: Bool {
        switch session.phase {
        case .idle, .discarded, .clipboard, .notCleaned: false
        default: true
        }
    }

    /// Only once there is text: the placeholder alone is not worth a line.
    private var showsText: Bool {
        guard preferences.showsText, session.hasRealText else { return false }
        switch session.phase {
        case .idle, .discarded, .clipboard, .notCleaned: return false
        default: return true
        }
    }
}

// MARK: - Strip

/// Status or waveform on the left, then microphone, eye and × together at the
/// right, always in the same place. Only the left part changes with the state.
private struct Strip: View {
    let session: Session
    @Bindable var preferences: Preferences
    /// Full card: the waveform spreads over all the room there is. Pill: a
    /// short waveform, so the pill stays small.
    let wide: Bool
    let onDrag: (Bool) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            middle
            microphone
            eye
            close
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: CardView.rowHeight)
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
            // While listening the moving bars say it; only a pause gets a word.
            if session.phase == .paused { label(de("Pausiert", en: "Paused")) }
            // Long and short waves cross-fade instead of reshuffling bars,
            // on top of each other: side by side in the row, both would
            // squeeze in for a moment and shove the row about.
            ZStack(alignment: .trailing) {
                Waveform(levels: wide ? session.levels : Array(session.levels.suffix(12)),
                         live: session.phase == .listening, spread: true)
                    .id(wide)
                    .transition(.opacity)
            }
            // The long wave is laid out at the full width straight away.
            .clipped()
        case .finishing:
            WritingDots()
            label(session.isCleaning ? de("Räumt auf", en: "Cleaning up") : de("Schreibt", en: "Writing"))
            if wide { Spacer(minLength: 0) }
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
            if wide { Spacer(minLength: 0) }
        case .discarded:
            label(de("Verworfen", en: "Discarded"))
            Button(action: session.undoDiscard) {
                Text(de("Rückgängig", en: "Undo")).underline()
            }
            .buttonStyle(.plain)
            .font(Typography.text(13, .semibold))
            .foregroundStyle(theme.accent)
            Spacer(minLength: 4)
        case .clipboard:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
            label(de("Zwischenablage", en: "Clipboard"))
            KeyLabel(glyph: "⌘", name: "V")
            Spacer(minLength: 4)
        case .notCleaned:
            // The original went in; why is in the history and the log.
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
            label(de("Nicht aufgeräumt", en: "Not cleaned up"))
            Spacer(minLength: 4)
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
                .background(Circle().fill(listening ? theme.signal : .white.opacity(0.12)))
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

    /// Capped and cut short, whole on hover: a long microphone error grew the
    /// pill past its window and was cut off on the left.
    private func label(_ text: String) -> some View {
        Text(text)
            .font(Typography.text(12, .medium))
            .foregroundStyle(theme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .help(text)
    }
}

// MARK: - Pieces

/// Bars driven by microphone loudness, newest on the right. Flat and dimmed
/// while paused. Spread, the bars share out all the width they are given.
struct Waveform: View {
    let levels: [Float]
    var live = true
    var spread = false
    @Environment(\.theme) private var theme

    private let maxHeight: CGFloat = 16

    var body: some View {
        HStack(alignment: .center, spacing: spread ? 0 : 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(theme.accent.opacity(live ? 1 : 0.45))
                    .frame(width: 2.5, height: 2.5 + (maxHeight - 2.5) * CGFloat(max(0, min(1, live ? level : 0))))
                    .frame(maxWidth: spread ? .infinity : nil)
            }
        }
        .frame(maxWidth: spread ? .infinity : nil)
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
