import AppKit
import SatzKit
import SwiftUI

/// What opens under the menu bar icon.
///
/// Ordered by how often each thing is needed: the last text is why anyone
/// opens it, so it leads. Status says nothing while everything works; when
/// something breaks, the problem takes the top and the rest steps back.
struct PopoverView: View {
    let history: History
    let discarded: Discarded
    let setup: Setup
    let shortcut: Shortcut
    let preferences: Preferences
    let actions: PopoverActions

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            problem

            if let latest = history.entries.first {
                LatestCard(entry: latest)
                EarlierRows(entries: Array(history.entries.dropFirst()))
            } else if discarded.last == nil {
                EmptyHint(trigger: preferences.trigger, mode: preferences.triggerMode)
            }

            if let snapshot = discarded.last {
                DiscardedRow(preview: snapshot.preview, restore: actions.restore)
            }

            Rule()

            Footer(preferences: preferences, actions: actions)
        }
        .id(preferences.language)
        .padding(12)
        .frame(width: 340)
        // No blue keyboard-focus ring on the copy button when the menu opens.
        .focusEffectDisabled()
        .onAppear { setup.refresh() }
        .background(theme.ground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1.5))
    }

    /// At most one thing is wrong at a time, in order of how much it blocks.
    @ViewBuilder
    private var problem: some View {
        if !setup.isComplete {
            ProblemCard(title: de("Einrichtung fehlt", en: "Setup incomplete"), primary: (de("Einrichten", en: "Set up"), actions.openSetup))
        } else if shortcut.status == .taken {
            ProblemCard(title: de("Tasten belegt", en: "Keys taken"), primary: (de("Ändern", en: "Change"), actions.openSettings))
        }
    }

}

/// What the popover can ask the app to do.
struct PopoverActions {
    /// Brings the last discarded dictation back into the card.
    var restore: () -> Void = {}
    var openSetup: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

// MARK: - Pieces

private struct ProblemCard: View {
    let title: String
    var detail: String?
    let primary: (String, () -> Void)
    var secondary: (String, () -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(Typography.display(18))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(Typography.mono(12))
                        .foregroundStyle(theme.inkOnCard)
                }
            }
            .foregroundStyle(theme.ink)

            HStack(spacing: 8) {
                Button(primary.0, action: primary.1).buttonStyle(.accent)
                if let secondary {
                    Button(secondary.0, action: secondary.1).buttonStyle(.outline)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// The last dictation thrown away with ×, one click from coming back.
private struct DiscardedRow: View {
    let preview: String
    let restore: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Rule()
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                Text(preview.isEmpty ? de("Aufnahme ohne Text", en: "Recording without text") : preview)
                    .font(Typography.text(14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: restore) {
                    Label(de("Zurückholen", en: "Restore"), systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.outlineCompact)
            }
            .foregroundStyle(theme.inkSecondary)
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
    }
}

private struct LatestCard: View {
    let entry: History.Entry
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.text)
                .font(Typography.text(16))
                .lineSpacing(3)
                .lineLimit(4)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Image(systemName: entry.pasted ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                Text(meta)
                    .font(Typography.text(13))
                Spacer()
                CopyButton(text: entry.text)
            }
            .foregroundStyle(theme.inkOnCard)
        }
        .padding(14)
        .surface()
    }

    private var meta: String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        return "\(entry.pasted ? (entry.app ?? de("Eingefügt", en: "Pasted")) : de("Zwischenablage", en: "Clipboard")) · \(time)"
    }
}

private struct EarlierRows: View {
    let entries: [History.Entry]

    var body: some View {
        if !entries.isEmpty {
            VStack(spacing: 0) {
                ForEach(entries) { EarlierRow(entry: $0) }
            }
        }
    }
}

/// One line per older text. The whole row copies; the pointer shows how.
private struct EarlierRow: View {
    let entry: History.Entry
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 10) {
                Text(entry.text)
                    .font(Typography.text(14.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hovering || copied {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.ink)
                } else {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(Typography.mono(12))
                        .foregroundStyle(theme.inkSecondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(de("Kopieren", en: "Copy"))
    }

    private func copy() {
        Clipboard.put(entry.text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.put(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)
        }
        .buttonStyle(AccentButtonStyle(height: 34, square: true))
        .help(de("Kopieren", en: "Copy"))
    }
}

/// Shown until the first dictation: the one thing a new user needs, which is
/// how to start. It goes away for good once there is history.
private struct EmptyHint: View {
    let trigger: Trigger
    let mode: TriggerMode
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeyLabel(glyph: key.glyph, name: key.name)
                }
            }
            Text(words)
                .font(Typography.text(14))
                .foregroundStyle(theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.control, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }

    private var keys: [(glyph: String, name: String?)] {
        let shown = trigger.display.keys
        // Two caps say "twice" faster than the word does.
        return trigger == .doubleRightCommand ? shown + shown : shown
    }

    private var words: String {
        let act = mode == .hold ? de("halten und sprechen", en: "hold and talk") : de("sprechen", en: "talk")
        switch trigger {
        case .doubleRightCommand:
            return mode == .hold ? de("Rechts zweimal tippen, beim zweiten Mal halten und sprechen", en: "Tap right twice, hold the second time and talk") : de("Rechts zweimal tippen und sprechen", en: "Tap right twice and talk")
        case .keys:
            return mode == .hold ? de("Halten und sprechen", en: "Hold and talk") : de("Drücken und sprechen", en: "Press and talk")
        case .mouseButton:
            let button = trigger.display.words ?? de("Maustaste", en: "Mouse button")
            return de("\(button) drücken, \(act)", en: "Press \(button), \(act)")
        }
    }
}

private struct Footer: View {
    let preferences: Preferences
    let actions: PopoverActions
    @Environment(\.theme) private var theme
    @State private var devices: [InputDevice] = []

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Choice(title: de("Wie in macOS", en: "Same as macOS"), selected: preferences.inputDeviceUID == nil) {
                    preferences.inputDeviceUID = nil
                }
                Divider()
                ForEach(devices) { device in
                    Choice(title: device.name, selected: preferences.inputDeviceUID == device.uid) {
                        preferences.inputDeviceUID = device.uid
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic")
                        .font(.system(size: 12, weight: .medium))
                    Text(currentName)
                        .font(Typography.text(14))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(theme.inkSecondary)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onAppear { devices = InputDevices.all() }

            Spacer()

            Button(action: actions.openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.icon)
            .help(de("Einstellungen", en: "Settings"))

            Button(action: actions.quit) {
                Image(systemName: "power")
            }
            .buttonStyle(.icon)
            .help(de("satz beenden", en: "Quit satz"))
        }
    }

    private var currentName: String {
        if let uid = preferences.inputDeviceUID, let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return InputDevices.systemDefault()?.name ?? de("Mikrofon", en: "Microphone")
    }
}

/// A menu item with a checkmark when it is the current choice.
private struct Choice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Puts text on the general pasteboard.
enum Clipboard {
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
