import SatzKit
import SwiftUI

/// Everything changed rarely. Labels and controls only: each control says what
/// it does, so none of them needs a sentence underneath.
struct SettingsView: View {
    let preferences: Preferences
    let setup: Setup
    let shortcut: Shortcut
    let launchAtLogin: LaunchAtLogin
    let history: History

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // ImageRenderer draws a ScrollView's content as nothing.
            content.background(theme.ground)
        } else {
            ScrollView { content }
                .scrollIndicators(.never)
                .frame(width: 520, height: 720)
                .background(theme.ground)
                .task {
                    // Permissions are granted in System Settings, which gives
                    // the app no signal when it happens. Polling is the only
                    // way to notice.
                    while !Task.isCancelled {
                        setup.refresh()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 26) {
                Text("Einstellungen")
                    .font(Typography.display(26))
                    .foregroundStyle(theme.ink)
                Block(title: "Kurzbefehl") {
                    ShortcutChoice(preferences: preferences, setup: setup, shortcut: shortcut)
                }
                MicrophoneBlock(preferences: preferences)
                ProviderBlock(preferences: preferences, setup: setup)
                WordsBlock(preferences: preferences)
                ReplacementsBlock(preferences: preferences)
                GeneralBlock(launchAtLogin: launchAtLogin, history: history)
            }
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .padding(.bottom, 32)
            .frame(width: 520, alignment: .leading)
    }
}

// MARK: - Mikrofon

private struct MicrophoneBlock: View {
    @Bindable var preferences: Preferences
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var devices: [InputDevice] = []

    var body: some View {
        Block(title: "Mikrofon") {
            HStack(spacing: 12) {
                if isSnapshot {
                    deviceLabel
                } else {
                    Menu {
                        Button("Wie in macOS") { preferences.inputDeviceUID = nil }
                        Divider()
                        ForEach(devices) { device in
                            Button(device.name) { preferences.inputDeviceUID = device.uid }
                        }
                    } label: {
                        deviceLabel
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Spacer()
                LevelMeter(deviceUID: preferences.inputDeviceUID)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .surface(radius: 16)
        }
        .onAppear { if !isSnapshot { devices = InputDevices.all() } }
    }

    private var deviceLabel: some View {
        HStack(spacing: 8) {
            Text(currentName).font(Typography.text(15, .semibold))
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(theme.ink)
        .contentShape(Rectangle())
    }

    private var currentName: String {
        if let uid = preferences.inputDeviceUID, let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        if isSnapshot { return "MacBook Pro-Mikrofon" }
        return InputDevices.systemDefault()?.name ?? "Wie in macOS"
    }
}

/// Bars that come alive for a few seconds when clicked. Not always on: a live
/// meter would keep the microphone, and the orange privacy dot, on the whole
/// time the window is open.
private struct LevelMeter: View {
    let deviceUID: String?
    @Environment(\.theme) private var theme
    @State private var levels: [Float] = Array(repeating: 0, count: 9)
    @State private var testing = false

    var body: some View {
        Button(action: test) {
            HStack(spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(level > 0.02 ? theme.accent : theme.hairline)
                        .frame(width: 4, height: 6 + 12 * CGFloat(level))
                }
            }
            .frame(height: 18)
            .animation(.easeOut(duration: 0.1), value: levels)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(testing)
        .help("Testen")
    }

    private func test() {
        testing = true
        var settings = AudioRecorder.Settings()
        settings.inputDeviceID = InputDevices.id(forUID: deviceUID)
        let recorder = AudioRecorder(settings: settings)
        recorder.onLevel = { level in
            levels.removeFirst()
            levels.append(level)
        }
        Task {
            try? await recorder.start()
            try? await Task.sleep(for: .seconds(4))
            recorder.cancel()
            levels = Array(repeating: 0, count: levels.count)
            testing = false
        }
    }
}

// MARK: - Anbieter

private struct ProviderBlock: View {
    @Bindable var preferences: Preferences
    let setup: Setup
    @Environment(\.theme) private var theme

    var body: some View {
        Block(title: "Anbieter") {
            VStack(spacing: 0) {
                Segmented(options: Provider.allCases.map { (value: $0, label: $0.name) }, selection: $preferences.provider)
                    .padding(10)
                Rule()
                KeyRow(setup: setup, provider: preferences.provider)
                Rule()
                FieldRow(label: "Modell", text: $preferences.model, prompt: preferences.provider.defaultModel)
                // Only MAI-Transcribe has a clean mode; elsewhere the switch would do nothing.
                if preferences.model.contains("mai-transcribe") {
                    Rule()
                    Toggle(isOn: $preferences.removesFillers) { Text("Füllwörter weglassen") }
                        .toggleStyle(AccentToggleStyle())
                        .font(Typography.text(15))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                }
                if preferences.provider == .custom {
                    Rule()
                    FieldRow(label: "Adresse", text: $preferences.customBaseURL, prompt: "https://…/v1")
                }
            }
            .surface(radius: 16)
        }
        .onChange(of: preferences.provider) { setup.refresh() }
    }
}

private struct KeyRow: View {
    let setup: Setup
    let provider: Provider

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var editing = false
    @State private var input = ""
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 13, weight: .medium))
            if editing || !setup.hasKey {
                // Always empty when opened: the stored key is never read back
                // into a field, where it would sit in memory for no reason.
                if isSnapshot {
                    Text(provider.keyPlaceholder).font(Typography.mono(13)).foregroundStyle(theme.inkOnCard)
                } else {
                    SecureField("", text: $input, prompt: Text(provider.keyPlaceholder).foregroundStyle(theme.inkOnCard))
                        .textFieldStyle(.plain)
                        .font(Typography.mono(13))
                        .onSubmit(save)
                }
                Spacer()
                Button("Sichern", action: save)
                    .buttonStyle(.outlineCompact)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Text("Schlüssel")
                Spacer()
                Button("Ändern") { editing = true }.buttonStyle(.outlineCompact)
            }
        }
        .font(Typography.text(15))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .onChange(of: provider) { close() }
        .help(problem ?? "")
    }

    private func save() {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try setup.store(key: key)
            problem = nil
            close()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func close() {
        input = ""
        editing = false
    }
}

private struct FieldRow: View {
    let label: String
    @Binding var text: String
    let prompt: String

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Typography.text(15))
                .foregroundStyle(theme.ink)
            Spacer()
            Group {
                if isSnapshot {
                    // ImageRenderer cannot draw AppKit-backed fields.
                    Text(text.isEmpty ? prompt : text)
                } else {
                    TextField("", text: $text, prompt: Text(prompt).foregroundStyle(theme.inkOnCard))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            }
            .font(Typography.mono(13))
            .foregroundStyle(theme.inkOnCard)
            .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

// MARK: - Wortschatz

private struct WordsBlock: View {
    let preferences: Preferences
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var adding = false
    @State private var newWord = ""
    @FocusState private var focused: Bool

    var body: some View {
        Block(title: "Wortschatz") {
            FlowLayout(spacing: 8) {
                ForEach(preferences.words, id: \.self) { word in
                    HStack(spacing: 6) {
                        Text(word).font(Typography.text(14))
                        Button { preferences.removeWord(word) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Entfernen")
                    }
                    .foregroundStyle(theme.ink)
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .frame(height: 28)
                    .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 1.5))
                }
                addChip
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: 16)
        }
    }

    @ViewBuilder
    private var addChip: some View {
        if adding && !isSnapshot {
            TextField("", text: $newWord, prompt: Text("Wort").foregroundStyle(theme.inkOnCard))
                .textFieldStyle(.plain)
                .font(Typography.text(14))
                .focused($focused)
                .onSubmit(add)
                .frame(width: 140)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .overlay(Capsule().strokeBorder(theme.control, lineWidth: 1.5))
                .onAppear { focused = true }
                .onChange(of: focused) { _, isFocused in if !isFocused { add() } }
        } else {
            Button { adding = true } label: {
                Text("+ Wort")
                    .font(Typography.text(14))
                    .foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .overlay(Capsule().strokeBorder(theme.control, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func add() {
        preferences.addWord(newWord)
        newWord = ""
        adding = false
    }
}

// MARK: - Ersetzungen

/// Spoken words that become symbols, as chips like the Wortschatz:
/// "Klammer auf → (". Only the ones that are on are shown.
private struct ReplacementsBlock: View {
    @Bindable var preferences: Preferences
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var adding = false
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        Block(title: "Ersetzungen") {
            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 8) {
                    ForEach(preferences.replacements.filter(\.isOn)) { rule in
                        HStack(spacing: 6) {
                            Text(rule.spoken).font(Typography.text(14))
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.inkSecondary)
                            Text(Self.shown(rule.written)).font(Typography.mono(13, .medium))
                            Button { preferences.replacements.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .help("Entfernen")
                        }
                        .foregroundStyle(theme.ink)
                        .padding(.leading, 12)
                        .padding(.trailing, 9)
                        .frame(height: 28)
                        .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 1.5))
                    }
                    if !adding || isSnapshot {
                        Button { adding = true } label: {
                            Text("+ Ersetzung")
                                .font(Typography.text(14))
                                .foregroundStyle(theme.inkSecondary)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .overlay(Capsule().strokeBorder(theme.control, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if adding && !isSnapshot {
                    HStack(spacing: 8) {
                        TextField("", text: $spoken, prompt: Text("gesagt, z. B. XX").foregroundStyle(theme.inkOnCard))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                        TextField("", text: $written, prompt: Text("geschrieben").foregroundStyle(theme.inkOnCard))
                            .onSubmit(add)
                        Button("Hinzufügen", action: add).buttonStyle(.outlineCompact)
                    }
                    .textFieldStyle(.plain)
                    .font(Typography.text(14))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: 16)
        }
    }

    /// Line breaks and spaces are invisible, so they get a sign.
    static func shown(_ written: String) -> String {
        switch written {
        case "\n": "↵"
        case "\n\n": "¶"
        case " ": "␣"
        default: written
        }
    }

    private func add() {
        let said = spoken.trimmingCharacters(in: .whitespaces)
        // "\n" typed as two characters means a line break.
        let result = written.replacingOccurrences(of: "\\n", with: "\n")
        guard !said.isEmpty, !result.isEmpty else {
            adding = false
            return
        }
        preferences.replacements.append(Replacement(spoken: said, written: result))
        spoken = ""
        written = ""
        adding = false
    }
}

// MARK: - Allgemein

private struct GeneralBlock: View {
    let launchAtLogin: LaunchAtLogin
    let history: History
    @Environment(\.theme) private var theme

    var body: some View {
        Block(title: "Allgemein") {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) })) {
                    Text("Bei Anmeldung starten")
                }
                .toggleStyle(AccentToggleStyle())
                .padding(.horizontal, 16)
                .frame(height: 48)
                .help(launchAtLogin.problem ?? "")
                Rule()
                HStack {
                    Text("Verlauf")
                    Spacer()
                    Button("Leeren", action: history.clear)
                        .buttonStyle(.outlineCompact)
                        .disabled(history.entries.isEmpty)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
            }
            .font(Typography.text(15))
            .foregroundStyle(theme.ink)
            .surface(radius: 16)
        }
    }
}
