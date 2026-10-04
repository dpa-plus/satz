import SatzKit
import SwiftUI

/// First run: one step at a time, each one card, with a rail of icons on top
/// showing where you are. Steps that are already in place are skipped.
struct SetupView: View {
    let preferences: Preferences
    let setup: Setup
    let shortcut: Shortcut
    let history: History
    let onDone: () -> Void

    enum Step: Int, CaseIterable {
        case key, microphone, trigger, paste, probe
    }

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var step: Step
    @State private var furthest: Step

    init(preferences: Preferences, setup: Setup, shortcut: Shortcut, history: History,
         start: Step? = nil, onDone: @escaping () -> Void) {
        self.preferences = preferences
        self.setup = setup
        self.shortcut = shortcut
        self.history = history
        self.onDone = onDone
        let first = start ?? Self.firstOpenStep(setup: setup, preferences: preferences)
        _step = State(initialValue: first)
        _furthest = State(initialValue: first)
    }

    /// Where a returning user picks up: the first thing that is missing.
    static func firstOpenStep(setup: Setup, preferences: Preferences) -> Step {
        if !setup.hasKey || preferences.isEndpointMissing { return .key }
        if setup.microphone != .allowed { return .microphone }
        if !setup.canPaste && preferences.trigger.needsEventTap { return .paste }
        return .probe
    }

    var body: some View {
        VStack(spacing: 24) {
            StepRail(step: step, furthest: furthest, trigger: preferences.trigger) { chosen in
                step = chosen
            }
            card
        }
        .id(preferences.lookKey)
        .padding(.horizontal, 32)
        .padding(.top, 46)
        .padding(.bottom, 32)
        .frame(width: 460)
        .background(theme.ground)
        // No blue keyboard-focus ring on the first button when the window opens.
        .focusEffectDisabled()
        .task {
            guard !isSnapshot else { return }
            while !Task.isCancelled {
                setup.refresh()
                // Permissions are granted in System Settings; move on by
                // ourselves the moment one arrives.
                if step == .microphone, setup.microphone == .allowed { advance() }
                if step == .paste, setup.canPaste { advance() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .key: KeyStep(preferences: preferences, setup: setup, onNext: advance)
            case .microphone: MicrophoneStep(setup: setup)
            case .trigger: TriggerStep(preferences: preferences, setup: setup, shortcut: shortcut, onNext: advance)
            case .paste: PasteStep(preferences: preferences, setup: setup, onLater: advance)
            case .probe: ProbeStep(trigger: preferences.trigger, history: history, onDone: onDone)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: 20, lifted: true)
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        if next.rawValue > furthest.rawValue { furthest = next }
    }
}

// MARK: - Rail

private struct StepRail: View {
    let step: SetupView.Step
    let furthest: SetupView.Step
    let trigger: Trigger
    let choose: (SetupView.Step) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SetupView.Step.allCases, id: \.self) { item in
                if item != .key {
                    Rectangle()
                        .fill(item.rawValue <= furthest.rawValue ? theme.accent : theme.hairline)
                        .frame(width: 28, height: 1.5)
                }
                dot(item)
            }
        }
    }

    private func dot(_ item: SetupView.Step) -> some View {
        let current = item == step
        let done = item.rawValue < furthest.rawValue && !current
        return ZStack {
            if current {
                Circle().fill(theme.accent)
            } else if done {
                Circle().strokeBorder(theme.accent, lineWidth: 2)
            } else {
                Circle().strokeBorder(theme.control, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            Group {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                } else {
                    icon(item)
                }
            }
            .foregroundStyle(current ? theme.accentLabel : done ? theme.accent : theme.inkSecondary)
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .onTapGesture { if item.rawValue <= furthest.rawValue { choose(item) } }
        .help(title(item))
    }

    @ViewBuilder
    private func icon(_ item: SetupView.Step) -> some View {
        switch item {
        case .key: Image(systemName: "key").font(.system(size: 13, weight: .semibold))
        case .microphone: Image(systemName: "mic").font(.system(size: 13, weight: .semibold))
        case .trigger:
            if case .mouseButton = trigger {
                Image(systemName: "computermouse").font(.system(size: 13, weight: .semibold))
            } else {
                Text(trigger.display.keys.first?.glyph ?? "⌘").font(.system(size: 14, weight: .semibold))
            }
        case .paste: Image(systemName: "character.cursor.ibeam").font(.system(size: 13, weight: .semibold))
        case .probe: BrandMark(height: 11, color: step == .probe ? theme.accentLabel : theme.inkSecondary)
        }
    }

    private func title(_ item: SetupView.Step) -> String {
        switch item {
        case .key: de("Schlüssel", en: "Key")
        case .microphone: de("Mikrofon", en: "Microphone")
        case .trigger: de("Kurzbefehl", en: "Shortcut")
        case .paste: de("Einfügen", en: "Paste")
        case .probe: de("Probesatz", en: "Test sentence")
        }
    }
}

private struct StepTitle: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(Typography.display(22, .bold))
            .foregroundStyle(theme.ink)
    }
}

// MARK: - Steps

private struct KeyStep: View {
    @Bindable var preferences: Preferences
    let setup: Setup
    let onNext: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var input = ""
    @State private var problem: String?

    var body: some View {
        StepTitle(text: de("Anbieter und Schlüssel", en: "Provider and key"))
        Segmented(options: Provider.allCases.map { (value: $0, label: $0.name) }, selection: $preferences.provider)

        HStack(spacing: 10) {
            Image(systemName: setup.hasKey ? "checkmark" : "lock")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(setup.hasKey ? theme.accent : theme.inkOnCard)
            if isSnapshot {
                Text(setup.hasKey ? de("Schlüssel gespeichert", en: "Key saved") : preferences.provider.keyPlaceholder)
                    .foregroundStyle(theme.inkOnCard)
                Spacer()
            } else {
                SecureField("", text: $input, prompt: Text(setup.hasKey ? de("Schlüssel gespeichert", en: "Key saved") : preferences.provider.keyPlaceholder)
                    .foregroundStyle(theme.inkOnCard))
                    .textFieldStyle(.plain)
                    .onSubmit(next)
            }
        }
        .font(Typography.mono(14))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))

        if preferences.provider == .custom {
            HStack(spacing: 10) {
                Image(systemName: "link").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.inkOnCard)
                if isSnapshot {
                    Text(preferences.customBaseURL.isEmpty ? "https://…/v1" : preferences.customBaseURL)
                    Spacer()
                } else {
                    TextField("", text: $preferences.customBaseURL, prompt: Text("https://…/v1").foregroundStyle(theme.inkOnCard))
                        .textFieldStyle(.plain)
                }
            }
            .font(Typography.mono(14))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))
        }

        if let problem {
            Text(problem).font(Typography.text(13)).foregroundStyle(theme.inkSecondary)
        }

        HStack {
            Button(de("Weiter", en: "Continue"), action: next)
                .buttonStyle(AccentButtonStyle(height: 42))
                .disabled(!canContinue)
            Spacer()
            if let page = preferences.provider.keyPage {
                Button { NSWorkspace.shared.open(page) } label: {
                    Text(de("Schlüssel holen", en: "Get a key")).font(Typography.text(14)).underline().foregroundStyle(theme.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: preferences.provider) { input = ""; problem = nil; setup.refresh() }
    }

    private var canContinue: Bool {
        let typed = !input.trimmingCharacters(in: .whitespaces).isEmpty
        return (typed || setup.hasKey) && !preferences.isEndpointMissing
    }

    private func next() {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                try setup.store(key: key)
                input = ""
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        guard setup.hasKey, !preferences.isEndpointMissing else { return }
        onNext()
    }
}

private struct MicrophoneStep: View {
    let setup: Setup

    var body: some View {
        StepTitle(text: de("Mikrofon", en: "Microphone"))
        Button(de("Erlauben", en: "Allow")) { Task { await setup.requestMicrophone() } }
            .buttonStyle(AccentButtonStyle(height: 42))
    }
}

private struct TriggerStep: View {
    let preferences: Preferences
    let setup: Setup
    let shortcut: Shortcut
    let onNext: () -> Void

    var body: some View {
        StepTitle(text: de("Kurzbefehl", en: "Shortcut"))
        ShortcutChoice(preferences: preferences, setup: setup, shortcut: shortcut)
        Button(de("Weiter", en: "Continue"), action: onNext)
            .buttonStyle(AccentButtonStyle(height: 42))
    }
}

private struct PasteStep: View {
    let preferences: Preferences
    let setup: Setup
    let onLater: () -> Void

    var body: some View {
        StepTitle(text: de("In andere Apps einfügen", en: "Paste into other apps"))
        HStack(spacing: 8) {
            Button(de("Erlauben", en: "Allow"), action: setup.requestPaste)
                .buttonStyle(AccentButtonStyle(height: 42))
            // Right ⌘ twice and the mouse button need the same permission to
            // work at all, so only a key combination can skip it. The text then
            // lands on the clipboard instead.
            if !preferences.trigger.needsEventTap {
                Button(de("Später", en: "Later"), action: onLater).buttonStyle(.outline)
            }
        }
    }
}

private struct ProbeStep: View {
    let trigger: Trigger
    let history: History
    let onDone: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var text = ""
    @State private var seen: History.Entry.ID?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            StepTitle(text: de("Probesatz", en: "Test sentence"))
            Spacer()
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeyLabel(glyph: key.glyph, name: key.name)
                }
                if let words = trigger == .doubleRightCommand ? de("rechts", en: "right") : trigger.display.words {
                    Text(words).font(Typography.text(13)).foregroundStyle(theme.inkOnCard)
                }
            }
        }

        Group {
            if isSnapshot {
                Text(text.isEmpty ? " " : text)
                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 66)
            }
        }
        .font(Typography.text(15))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1.5))

        HStack(spacing: 8) {
            if arrived {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.accent)
                Text(de("Angekommen", en: "Arrived")).font(Typography.text(15, .semibold)).foregroundStyle(theme.ink)
            }
            Spacer()
            if arrived {
                Button(de("Fertig", en: "Done"), action: onDone).buttonStyle(AccentButtonStyle(height: 42))
            } else {
                Button(de("Fertig", en: "Done"), action: onDone).buttonStyle(.outline)
            }
        }
        .onAppear {
            seen = history.entries.first?.id
            focused = true
        }
        .onChange(of: history.entries.first?.id) { _, newest in
            // The dictation lands here when pasting works. When it only reached
            // the clipboard, show it anyway: the point is that it arrived.
            guard newest != seen, let entry = history.entries.first else { return }
            seen = newest
            if !text.contains(entry.text) { text = entry.text }
        }
    }

    private var arrived: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Two caps for "twice".
    private var keys: [(glyph: String, name: String?)] {
        let shown = trigger.display.keys
        return trigger == .doubleRightCommand ? shown + shown : shown
    }
}

extension Provider {
    /// Where to create a key, for the setup's "Schlüssel holen".
    var keyPage: URL? {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .custom: nil
        }
    }
}
