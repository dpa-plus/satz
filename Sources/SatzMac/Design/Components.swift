import SwiftUI

// The handful of pieces every surface is built from. Each reads the theme, so
// the same code draws sand in light mode and petrol in dark mode.

/// The logo mark: seven bars shaped like a sound.
struct BrandMark: View {
    var height: CGFloat = 22
    var color: Color?

    @Environment(\.theme) private var theme
    private let shape: [CGFloat] = [0.30, 0.55, 0.80, 1.00, 0.80, 0.55, 0.30]

    var body: some View {
        let bar = height / 6.5
        HStack(spacing: bar * 0.76) {
            ForEach(Array(shape.enumerated()), id: \.offset) { _, scale in
                Capsule()
                    .fill(color ?? theme.accent)
                    .frame(width: bar, height: height * (0.25 + 0.75 * scale))
            }
        }
        .frame(height: height)
    }
}

/// A lifted surface: white with an ink edge in light mode, a faint panel in dark.
struct SurfaceModifier: ViewModifier {
    var radius: CGFloat = 14
    var lifted = false

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.card)
                    // The brand's sticker shadow: a hard offset, no blur. On
                    // the shape only; on the whole view every label inside
                    // would get a ghost copy under it.
                    .shadow(color: lifted ? theme.cardBorder.opacity(0.09) : .clear, radius: 0, y: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1.5))
    }
}

extension View {
    func surface(radius: CGFloat = 14, lifted: Bool = false) -> some View {
        modifier(SurfaceModifier(radius: radius, lifted: lifted))
    }
}

/// A hairline between rows.
struct Rule: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle().fill(theme.hairline).frame(height: 1.5)
    }
}

/// A key as printed on the keyboard: the glyph and, where it helps, its name.
/// Never the glyph alone; on a non-Apple keyboard "⌥" means nothing.
struct KeyLabel: View {
    let glyph: String
    var name: String?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(glyph).font(.system(size: 12, weight: .semibold))
            if let name {
                Text(name).font(Typography.text(13, .medium))
            }
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1.5))
    }
}

/// The one action that matters on a surface. Orange with an ink label.
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    /// For an icon on its own: as wide as it is tall.
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        AccentButton(configuration: configuration, height: height, square: square)
    }

    private struct AccentButton: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let square: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Typography.text(15, .semibold))
                .foregroundStyle(theme.accentLabel)
                .padding(.horizontal, square ? 0 : 16)
                .frame(minWidth: height, minHeight: height)
                .frame(width: square ? height : nil)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accent)
                        // On the shape, not the label, or the label gets a ghost.
                        .shadow(color: theme.accentShadow, radius: 0, y: configuration.isPressed ? 1 : 3)
                )
                .offset(y: configuration.isPressed ? 2 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// Everything available but not urgent.
struct OutlineButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        OutlineButton(configuration: configuration, compact: compact)
    }

    private struct OutlineButton: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                .font(Typography.text(compact ? 13 : 15, .semibold))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(minHeight: compact ? 26 : 34)
                .background(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// An icon that behaves like a button and highlights under the pointer.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }

    private struct IconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.theme) private var theme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? theme.hover : .clear))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
    static var outlineCompact: OutlineButtonStyle { OutlineButtonStyle(compact: true) }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

/// A choice between a few options that should all be visible at once.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(Typography.text(14, .semibold))
                        .foregroundStyle(chosen ? theme.ink : theme.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(chosen ? theme.card : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(chosen ? theme.cardBorder : .clear, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.hairline))
    }
}

/// A radio button's circle.
struct RadioMark: View {
    let selected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? theme.accent : theme.cardBorder, lineWidth: selected ? 2 : 1.5)
            if selected {
                Circle().fill(theme.accent).frame(width: 8, height: 8)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// An on/off switch in the brand's orange.
struct AccentToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentSwitch(configuration: configuration)
    }

    private struct AccentSwitch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.theme) private var theme

        var body: some View {
            HStack {
                configuration.label
                Spacer()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? theme.accent : theme.control.opacity(0.5))
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                }
                .frame(width: 38, height: 22)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            // The label switches it too, like a system toggle's does.
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// A section of a settings-like window: a Bitter heading over its surface.
struct Block<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Typography.display(17))
                .foregroundStyle(theme.ink)
            content
        }
    }
}

/// The surface of a floating piece (the card, the menu): Liquid Glass tinted
/// with the theme's ground on macOS 26, so the desktop shows through and the
/// text still reads; the solid ground with a soft shadow before that, and in
/// snapshots, which cannot draw glass.
///
/// Glass alone takes its brightness from whatever is behind it: over a white
/// page the card came up whitish, then turned green, and changed shade again
/// as it grew. The theme's colour laid over the glass keeps it one colour
/// everywhere, with only a little of the desktop showing through.
struct GlassSurface: View {
    let cornerRadius: CGFloat
    let tint: Color
    var snapshot = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), !snapshot {
            ZStack {
                Color.clear.glassEffect(.regular.tint(tint), in: shape)
                shape.fill(tint.opacity(0.65))
            }
        } else {
            shape.fill(tint).shadow(color: .black.opacity(0.32), radius: 14, y: 6)
        }
    }
}
