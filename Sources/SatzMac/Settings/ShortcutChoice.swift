import SwiftUI

/// Picks what starts a dictation: right ⌘ twice, your own keys, or a mouse
/// button, and whether you tap it or hold it. Used by Settings and Setup.
struct ShortcutChoice: View {
    @Bindable var preferences: Preferences
    let setup: Setup
    let shortcut: Shortcut

    @Environment(\.theme) private var theme
    @State private var recording: TriggerRecorder.Kind?
    @State private var recorder = TriggerRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                OptionRow(selected: preferences.trigger == .doubleRightCommand) {
                    stopRecording()
                    preferences.trigger = .doubleRightCommand
                } label: {
                    KeyLabel(glyph: "⌘", name: "cmd")
                    Text("rechts, zweimal")
                }
                Rule()
                OptionRow(selected: isKeys) { record(.keys) } label: {
                    if recording == .keys {
                        Text("Tasten drücken …").foregroundStyle(theme.inkSecondary)
                    } else if isKeys {
                        ForEach(Array(preferences.trigger.display.keys.enumerated()), id: \.offset) { _, key in
                            KeyLabel(glyph: key.glyph, name: key.name)
                        }
                    } else {
                        Text("Eigene Tasten")
                    }
                    Spacer()
                    Button("Aufnehmen") { record(.keys) }.buttonStyle(.outlineCompact)
                }
                Rule()
                OptionRow(selected: isMouse) { record(.mouse) } label: {
                    if recording == .mouse {
                        Text("Maustaste drücken …").foregroundStyle(theme.inkSecondary)
                    } else {
                        Text(isMouse ? (preferences.trigger.display.words ?? "Maustaste") : "Maustaste")
                    }
                    Spacer()
                    Button("Aufnehmen") { record(.mouse) }.buttonStyle(.outlineCompact)
                }
            }
            .surface(radius: 16)

            Segmented(
                options: [(value: TriggerMode.tap, label: "Tippen"), (value: TriggerMode.hold, label: "Halten")],
                selection: $preferences.triggerMode
            )

            if shortcut.status == .needsAccessibility {
                Notice(text: "Braucht Bedienungshilfen", action: ("Erlauben", setup.requestPaste))
            } else if shortcut.status == .taken {
                Notice(text: "Von einem anderen Programm belegt")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var isKeys: Bool {
        if case .keys = preferences.trigger { true } else { false }
    }

    private var isMouse: Bool {
        if case .mouseButton = preferences.trigger { true } else { false }
    }

    private func record(_ kind: TriggerRecorder.Kind) {
        recording = kind
        // Pressing the old trigger while recording the new one must not start
        // a dictation.
        shortcut.pause()
        recorder.record(kind) { trigger in
            recording = nil
            if let trigger { preferences.trigger = trigger }
            shortcut.resume()
        }
    }

    private func stopRecording() {
        guard recording != nil else { return }
        recorder.stop()
        recording = nil
        shortcut.resume()
    }
}

/// A selectable row with a radio mark. Tapping anywhere on it chooses it.
struct OptionRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var label: Label

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            RadioMark(selected: selected)
            label
        }
        .font(Typography.text(15))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// A quiet line under a block when something needs doing.
struct Notice: View {
    let text: String
    var action: (String, () -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
            Text(text).font(Typography.text(14))
            Spacer()
            if let action {
                Button(action.0, action: action.1).buttonStyle(.outlineCompact)
            }
        }
        .foregroundStyle(theme.inkSecondary)
    }
}
