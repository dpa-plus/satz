import SwiftUI
import SatzKit

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
                    Text(de("rechts, zweimal", en: "right, twice"))
                }
                Rule()
                OptionRow(selected: isKeys) { record(.keys) } label: {
                    if recording == .keys {
                        Text(de("Tasten drücken …", en: "Press keys …")).foregroundStyle(theme.inkSecondary)
                    } else if isKeys {
                        ForEach(Array(preferences.trigger.display.keys.enumerated()), id: \.offset) { _, key in
                            KeyLabel(glyph: key.glyph, name: key.name)
                        }
                    } else {
                        Text(de("Eigene Tasten", en: "Own keys"))
                    }
                    Spacer()
                    Button(de("Aufnehmen", en: "Record")) { record(.keys) }.buttonStyle(.outlineCompact)
                }
                Rule()
                OptionRow(selected: isMouse) { record(.mouse) } label: {
                    if recording == .mouse {
                        Text(de("Maustaste drücken …", en: "Press a mouse button …")).foregroundStyle(theme.inkSecondary)
                    } else {
                        Text(isMouse ? (preferences.trigger.display.words ?? de("Maustaste", en: "Mouse button")) : de("Maustaste", en: "Mouse button"))
                    }
                    Spacer()
                    Button(de("Aufnehmen", en: "Record")) { record(.mouse) }.buttonStyle(.outlineCompact)
                }
            }
            .surface(radius: 16)

            Segmented(
                options: [(value: TriggerMode.tap, label: de("Tippen", en: "Tap")), (value: TriggerMode.hold, label: de("Halten", en: "Hold"))],
                selection: $preferences.triggerMode
            )

            if shortcut.status == .needsAccessibility {
                Notice(text: de("Braucht Bedienungshilfen", en: "Needs Accessibility"), action: (de("Erlauben", en: "Allow"), setup.requestPaste))
            } else if shortcut.status == .taken {
                Notice(text: de("Von einem anderen Programm belegt", en: "Taken by another app"))
            } else if shortcut.status == .takenByMacOS {
                Notice(text: de("macOS nutzt diese Tasten schon, andere wählen", en: "macOS already uses these keys, pick others"))
            } else if case .keys(let keyCode, let modifiers) = preferences.trigger,
                      HotKey.isOftenClaimed(.init(keyCode: keyCode, modifiers: modifiers)) {
                // Another app's hotkey cannot be seen, so said up front.
                Notice(text: de("Oft von Raycast, Alfred oder ChatGPT belegt", en: "Often taken by Raycast, Alfred or ChatGPT"))
            }
        }
        .onDisappear(perform: stopRecording)
        // Recording listens inside satz only, with the shortcut off meanwhile.
        // Switching to another app left it off until the user came back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
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
        // VoiceOver can choose the option, not only the record button in it.
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
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
