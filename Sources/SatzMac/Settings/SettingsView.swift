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
    let models: ModelStore

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // ImageRenderer draws a ScrollView's content as nothing.
            content.background(theme.ground)
        } else {
            ScrollView { content }
                .focusEffectDisabled()
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.ground)
                .task {
                    // Permissions are granted in System Settings, which gives
                    // the app no signal when it happens. Polling is the only
                    // way to notice.
                    while !Task.isCancelled {
                        setup.refresh()
                        launchAtLogin.refresh()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 26) {
                Block(title: de("Kurzbefehl", en: "Shortcut")) {
                    ShortcutChoice(preferences: preferences, setup: setup, shortcut: shortcut)
                }
                MicrophoneBlock(preferences: preferences)
                ProviderBlock(preferences: preferences, setup: setup, models: models)
                WordsBlock(preferences: preferences)
                ReplacementsBlock(preferences: preferences)
                GeneralBlock(preferences: preferences, launchAtLogin: launchAtLogin, history: history)
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(width: 560, alignment: .leading)
    }
}

// MARK: - Mikrofon

private struct MicrophoneBlock: View {
    @Bindable var preferences: Preferences
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var devices: [InputDevice] = []

    var body: some View {
        Block(title: de("Mikrofon", en: "Microphone")) {
            HStack(spacing: 12) {
                if isSnapshot {
                    deviceLabel
                } else {
                    Menu {
                        Button(de("Wie in macOS", en: "Same as macOS")) { preferences.inputDeviceUID = nil }
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
        if isSnapshot { return de("MacBook Pro-Mikrofon", en: "MacBook Pro Microphone") }
        return InputDevices.systemDefault()?.name ?? de("Wie in macOS", en: "Same as macOS")
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
        .help(de("Testen", en: "Test"))
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
    let models: ModelStore
    @Environment(\.theme) private var theme

    var body: some View {
        Block(title: de("Anbieter", en: "Provider")) {
            VStack(spacing: 0) {
                Segmented(options: Provider.allCases.map { (value: $0, label: $0.name) }, selection: $preferences.provider)
                    .padding(10)
                Rule()
                if preferences.provider.needsKey {
                    KeyRow(setup: setup, provider: preferences.provider)
                    Rule()
                }
                if preferences.provider == .custom {
                    FieldRow(label: de("Modell", en: "Model"), text: $preferences.model, prompt: preferences.provider.defaultModel)
                } else {
                    ModelRow(preferences: preferences, store: models)
                }
                if preferences.provider == .local {
                    Rule()
                    LocalModelRow(preferences: preferences)
                }
                // Only MAI-Transcribe has a clean mode; elsewhere the switch would do nothing.
                if preferences.model.contains("mai-transcribe") {
                    Rule()
                    Toggle(isOn: $preferences.removesFillers) { Text(de("Füllwörter weglassen", en: "Remove filler words")) }
                        .toggleStyle(AccentToggleStyle())
                        .font(Typography.text(15))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                }
                if preferences.provider == .custom {
                    Rule()
                    FieldRow(label: de("Adresse", en: "Address"), text: $preferences.customBaseURL, prompt: "https://…/v1")
                }
            }
            .surface(radius: 16)
        }
        .onChange(of: preferences.provider) { _, provider in
            setup.refresh()
            // A loaded model is a gigabyte of memory nobody uses any more.
            if provider.needsKey { LocalModels.shared.unload() }
            else { LocalModels.shared.warmUp(preferences.model, language: preferences.spokenLanguage) }
        }
        .onChange(of: preferences.model) { _, model in
            guard preferences.provider == .local else { return }
            if model == ModelCatalog.apple { LocalModels.shared.unload() }
            else { LocalModels.shared.warmUp(model, language: preferences.spokenLanguage) }
        }
    }
}

/// The model: a menu of what the provider offers now, best first, each with
/// how many words it gets wrong and what an hour of talking costs, and "Other"
/// for one typed in by hand. A plain text field let one stray keystroke break
/// every dictation after it.
private struct ModelRow: View {
    @Bindable var preferences: Preferences
    let store: ModelStore
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var typing = false
    /// What is typed in the Model ID field, saved only on Return or when the
    /// field is left: saved on every keystroke, one stray key changed the
    /// model, and the field wrote its old text back over a pick from the menu.
    @State private var draft = ""
    @FocusState private var idFocused: Bool

    private static let other = "\u{0}other"

    var body: some View {
        let provider = preferences.provider
        let list = store.models(for: provider)
        let current = provider.choice(for: preferences.model, in: list)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(de("Modell", en: "Model"))
                    .font(Typography.text(15))
                    .foregroundStyle(theme.ink)
                Spacer()
                if isSnapshot {
                    label(current)
                } else {
                    // A picker inside the menu: the choice is one value, so the
                    // menu always shows exactly what is chosen.
                    Menu {
                        Picker("", selection: selection(current)) {
                            ForEach(list) { model in
                                Text(Self.title(model)).tag(model.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Button(de("Anderes Modell …", en: "Other model …")) {
                            draft = preferences.model
                            typing = true
                        }
                    } label: { label(current) }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(de("Modell", en: "Model"))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Text(provider == .local ? Self.localFacts(current, spoken: preferences.spokenLanguage) : Self.facts(current))
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .padding(.top, -6)
            // A model typed in by hand keeps its field, so it can be read and changed.
            if typing || current == nil {
                Rule()
                HStack(spacing: 12) {
                    Text(de("Modell-ID", en: "Model ID"))
                        .font(Typography.text(15))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    if isSnapshot {
                        Text(preferences.model.isEmpty ? provider.defaultModel : preferences.model)
                    } else {
                        // Taking the keyboard selects the id, so typing replaces it.
                        TextField("", text: $draft, prompt: Text(provider.defaultModel).foregroundStyle(theme.inkOnCard))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .focused($idFocused)
                            .onSubmit { commit() }
                            // Escape keeps the model there was.
                            .onExitCommand {
                                draft = preferences.model
                                typing = false
                                idFocused = false
                            }
                    }
                }
                .font(Typography.mono(13))
                .foregroundStyle(theme.inkOnCard)
                .padding(.horizontal, 16)
                .frame(height: 48)
            }
        }
        // The field lets go first, with the new provider's model: its focus-out
        // wrote the old provider's model into the new one.
        .onChange(of: provider) {
            draft = preferences.model
            typing = false
            idFocused = false
        }
        .onChange(of: typing) { _, now in
            // Once the field is in the window: asked for as it appears, the
            // request was dropped (the same as the Wortschatz field).
            if now { Task { idFocused = true } }
        }
        // Leaving the field saves what was typed and closes it.
        .onChange(of: idFocused) { _, focused in if !focused { commit() } }
        .onAppear { draft = preferences.model }
        .onDisappear { typing = false }
        .task(id: provider) { if !isSnapshot { store.refresh(provider) } }
    }

    private func selection(_ current: ModelChoice?) -> Binding<String> {
        Binding(
            get: { current?.id ?? Self.other },
            set: { id in
                guard id != Self.other else { return }
                // The field lets go first, so nothing it still holds is saved over the pick.
                typing = false
                idFocused = false
                preferences.model = id
                draft = id
            }
        )
    }

    private func commit() {
        let id = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { preferences.model = id }
        draft = preferences.model
        typing = false
    }

    private func label(_ current: ModelChoice?) -> some View {
        HStack(spacing: 6) {
            Text(current.map { "\($0.maker) \($0.name)" } ?? de("Anderes", en: "Other"))
                .font(Typography.text(15))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(theme.inkOnCard)
        .contentShape(Rectangle())
    }

    private static var locale: Locale { Locale(identifier: Language.current == .english ? "en_US" : "de_DE") }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    private static func price(_ dollars: Double) -> String {
        dollars.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
    }

    /// One line in the menu: name, maker, errors, price.
    static func title(_ model: ModelChoice) -> String {
        var parts = ["\(model.name) · \(model.maker)"]
        if let rate = model.errorRate { parts.append(de("\(number(rate)) % Fehler", en: "\(number(rate)) % errors")) }
        if model.dollarsPerHour == 0 {
            parts.append(de("kostenlos", en: "free"))
        } else if let dollars = model.dollarsPerHour {
            parts.append(de("\(price(dollars)) pro Stunde", en: "\(price(dollars)) an hour"))
        }
        return parts.joined(separator: " · ")
    }

    /// Under the row: what the chosen model's numbers mean.
    static func facts(_ model: ModelChoice?) -> String {
        guard let model else { return de("Ein Modell, das nicht in der Liste steht.", en: "A model that is not in the list.") }
        let errors = model.errorRate.map { de("\(number($0)) % falsche Wörter laut Artificial Analysis", en: "\(number($0)) % wrong words per Artificial Analysis") }
            ?? de("Noch ohne Fehlerquote von Artificial Analysis", en: "No error rate from Artificial Analysis yet")
        let cost = model.dollarsPerHour.map { de("\(price($0)) pro Stunde Sprechen", en: "\(price($0)) per hour of talking") }
        return [errors, cost].compactMap { $0 }.joined(separator: ", ")
    }

    /// Under the row, for a model on this Mac: what it can and cannot do.
    static func localFacts(_ model: ModelChoice?, spoken: Language) -> String {
        switch model?.id {
        case ModelCatalog.apple?:
            de("In macOS eingebaut und kostenlos. Hört nur auf \(spoken.name), nimmt den Wortschatz kaum an.",
               en: "Built into macOS and free. Listens for \(spoken.name) only, barely takes the word list.")
        case nil:
            de("Ein WhisperKit-Modell, das nicht in der Liste steht.", en: "A WhisperKit model that is not in the list.")
        default:
            de("Läuft auf diesem Mac, ohne Internet und kostenlos. Erkennt Deutsch und Englisch von selbst.",
               en: "Runs on this Mac, offline and free. Tells German from English by itself.")
        }
    }
}

/// Whether the model for "Lokal" is on this Mac, and the one button that
/// changes that: load it, or put it in the Trash.
struct LocalModelRow: View {
    @Bindable var preferences: Preferences
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let local = LocalModels.shared
        let model = preferences.model
        let spoken = preferences.spokenLanguage
        let apple = model == ModelCatalog.apple
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                status(local.state(of: model, language: spoken), apple: apple)
            }
            .font(Typography.text(15))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            // Apple's listens for one language: chosen here as well, where it matters.
            if apple {
                Rule()
                HStack(spacing: 12) {
                    Text(de("Gesprochen auf", en: "Spoken in"))
                        .font(Typography.text(15))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Segmented(options: Language.allCases.map { (value: $0, label: $0.name) }, selection: $preferences.spokenLanguage)
                        .fixedSize()
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
            }
        }
        .task(id: "\(model)-\(spoken.rawValue)") {
            if !isSnapshot { await local.check(model, language: spoken) }
        }
    }

    @ViewBuilder
    private func status(_ state: LocalModels.State, apple: Bool) -> some View {
        let local = LocalModels.shared
        let model = preferences.model
        let spoken = preferences.spokenLanguage
        let size = ModelCatalog.downloadSize(of: model)
        switch state {
        case .ready:
            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
            Text(apple ? de("Auf diesem Mac", en: "On this Mac")
                       : de("Auf diesem Mac\(size.map { ", \($0)" } ?? "")", en: "On this Mac\(size.map { ", \($0)" } ?? "")"))
            Spacer()
            if !apple {
                Button(de("Entfernen", en: "Remove")) { local.remove(model) }
                    .buttonStyle(.outlineCompact)
                    .help(de("Legt das Modell in den Papierkorb", en: "Moves the model to the Trash"))
            }
        case .missing:
            Image(systemName: "arrow.down.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.inkSecondary)
            Text(de("Noch nicht auf diesem Mac", en: "Not on this Mac yet"))
            Spacer()
            Button(size.map { de("Laden, \($0)", en: "Download, \($0)") } ?? de("Laden", en: "Download")) {
                local.download(model, language: spoken)
            }
            .buttonStyle(AccentButtonStyle(height: 30))
        case .downloading(let fraction):
            Text(de("Wird geladen", en: "Downloading"))
            Spacer()
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(theme.accent)
                .frame(width: 140)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(Typography.mono(12))
                .monospacedDigit()
                .foregroundStyle(theme.inkSecondary)
                .frame(width: 40, alignment: .trailing)
        case .preparing:
            ProgressView().controlSize(.small)
            Text(de("Wird für diesen Mac vorbereitet, einmalig", en: "Getting ready for this Mac, once"))
            Spacer()
        case .unavailable(let why):
            Image(systemName: "xmark.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.inkSecondary)
            Text(why).foregroundStyle(theme.inkSecondary)
            Spacer()
        case .failed(let why):
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
            Text(de("Laden fehlgeschlagen", en: "Download failed"))
                .help(why)
            Spacer()
            Button(de("Nochmal", en: "Try again")) { local.download(model, language: spoken) }
                .buttonStyle(.outlineCompact)
        }
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
        VStack(alignment: .leading, spacing: 0) {
            row
                .frame(height: 48)
            // Said where it happened, not in a tooltip nobody hovers.
            if let problem {
                Text(problem)
                    .font(Typography.text(12))
                    .foregroundStyle(theme.accent)
                    .padding(.bottom, 12)
            }
        }
        .font(Typography.text(15))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 16)
        .onChange(of: provider) { close() }
    }

    private var row: some View {
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
                        // Escape keeps the key that is there.
                        .onExitCommand(perform: close)
                }
                Spacer()
                Button(de("Sichern", en: "Save"), action: save)
                    .buttonStyle(.outlineCompact)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                // "Ändern" can be taken back: the stored key stays.
                if editing && setup.hasKey {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.inkSecondary)
                    .help(de("Abbrechen", en: "Cancel"))
                }
            } else {
                Text(de("Schlüssel", en: "Key"))
                Spacer()
                Button(de("Ändern", en: "Change")) { editing = true }.buttonStyle(.outlineCompact)
            }
        }
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
        problem = nil
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
    @State private var removed: (index: Int, word: String)?
    @State private var forgetting: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        Block(title: de("Wortschatz", en: "Vocabulary")) {
            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 8) {
                    ForEach(preferences.words, id: \.self) { word in
                        HStack(spacing: 6) {
                            Text(word).font(Typography.text(14)).lineLimit(1).truncationMode(.middle)
                            Button { remove(word) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .help(de("Entfernen", en: "Remove"))
                        }
                        .foregroundStyle(theme.ink)
                        .padding(.leading, 12)
                        .padding(.trailing, 9)
                        .frame(height: 28)
                        .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 1.5))
                    }
                    addChip
                }
                if let removed {
                    UndoLine(label: de("„\(removed.word)“ entfernt", en: "Removed “\(removed.word)”")) {
                        preferences.words.insert(removed.word, at: min(removed.index, preferences.words.count))
                        self.removed = nil
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: 16)
        }
    }

    private func remove(_ word: String) {
        let index = preferences.words.firstIndex(of: word) ?? preferences.words.count
        preferences.removeWord(word)
        removed = (index, word)
        forgetting?.cancel()
        forgetting = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { removed = nil }
        }
    }

    @ViewBuilder
    private var addChip: some View {
        if adding && !isSnapshot {
            TextField("", text: $newWord, prompt: Text(de("Wort", en: "Word")).foregroundStyle(theme.inkOnCard))
                .textFieldStyle(.plain)
                .font(Typography.text(14))
                .focused($focused)
                .onSubmit(add)
                .frame(width: 140)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .overlay(Capsule().strokeBorder(theme.control, lineWidth: 1.5))
                // Asked for once the field is in the window. Asked for as it
                // appeared, the request was dropped, and the typing went to
                // the field that still had the keyboard: the model.
                .task { focused = true }
                .onChange(of: focused) { _, isFocused in if !isFocused { add() } }
                // Escape closes the field without adding anything.
                .onExitCommand {
                    newWord = ""
                    adding = false
                }
        } else {
            Button { adding = true } label: {
                Text(de("+ Wort", en: "+ Word"))
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
    @State private var removed: (index: Int, rule: Replacement)?
    @State private var forgetting: Task<Void, Never>?
    @FocusState private var typing: Bool

    var body: some View {
        Block(title: de("Ersetzungen", en: "Replacements")) {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: $preferences.usesReplacements) {
                    Text(de("Gesprochene Zeichen ersetzen", en: "Replace spoken symbols"))
                }
                .toggleStyle(AccentToggleStyle())
                .font(Typography.text(15))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 16)
                .frame(height: 48)
                if preferences.usesReplacements {
                    Rule()
                    // Apart from the app's language: the Mac in English, the
                    // dictation in German, or the other way round.
                    HStack {
                        Text(de("Gesprochen auf", en: "Spoken in"))
                        Spacer()
                        Segmented(options: Language.allCases.map { (value: $0, label: $0.name) },
                                  selection: $preferences.spokenLanguage)
                            .frame(width: 210)
                    }
                    .font(Typography.text(15))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    Rule()
                    rules
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: 16)
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                ForEach(preferences.replacements.filter(\.isOn)) { rule in
                    HStack(spacing: 6) {
                        Text(rule.spoken).font(Typography.text(14)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.inkSecondary)
                        Text(Self.shown(rule.written)).font(Typography.mono(13, .medium)).lineLimit(1).truncationMode(.middle)
                        Button { remove(rule) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help(de("Entfernen", en: "Remove"))
                    }
                    .foregroundStyle(theme.ink)
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .frame(height: 28)
                    .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 1.5))
                }
                if !adding || isSnapshot {
                    Button { adding = true } label: {
                        Text(de("+ Ersetzung", en: "+ Replacement"))
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
                    TextField("", text: $spoken, prompt: Text(de("gesagt, z. B. XX", en: "spoken, e.g. XX")).foregroundStyle(theme.inkOnCard))
                        .focused($typing)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                    TextField("", text: $written, prompt: Text(de("geschrieben", en: "written")).foregroundStyle(theme.inkOnCard))
                        .onSubmit(add)
                    Button(de("Hinzufügen", en: "Add"), action: add).buttonStyle(.outlineCompact)
                    Button(action: cancel) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(de("Schließen", en: "Close"))
                }
                // The first field takes the keyboard, as in the Wortschatz.
                .task { typing = true }
                // Escape closes the row without adding anything.
                .onExitCommand(perform: cancel)
                .textFieldStyle(.plain)
                .font(Typography.text(14))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))
            }
            if let removed {
                UndoLine(label: de("„\(removed.rule.spoken)“ entfernt", en: "Removed “\(removed.rule.spoken)”")) {
                    preferences.replacements.insert(removed.rule, at: min(removed.index, preferences.replacements.count))
                    self.removed = nil
                }
            }
        }
        .padding(12)
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

    private func remove(_ rule: Replacement) {
        let index = preferences.replacements.firstIndex { $0.id == rule.id } ?? preferences.replacements.count
        preferences.replacements.removeAll { $0.id == rule.id }
        removed = (index, rule)
        forgetting?.cancel()
        forgetting = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { removed = nil }
        }
    }

    private func cancel() {
        spoken = ""
        written = ""
        adding = false
    }

    private func add() {
        let said = spoken.trimmingCharacters(in: .whitespaces)
        // "\n" typed as two characters means a line break.
        let result = written.replacingOccurrences(of: "\\n", with: "\n")
        guard !said.isEmpty, !result.isEmpty else {
            adding = false
            return
        }
        // The same phrase again changes the rule there is: a second one stayed
        // in the list while the first still won.
        if let index = preferences.replacements.firstIndex(where: { $0.spoken.caseInsensitiveCompare(said) == .orderedSame }) {
            preferences.replacements[index].written = result
            preferences.replacements[index].isOn = true
        } else {
            preferences.replacements.append(Replacement(spoken: said, written: result))
        }
        spoken = ""
        written = ""
        adding = false
    }
}

/// "Removed … · Undo", for a few seconds after a chip goes.
private struct UndoLine: View {
    let label: String
    let undo: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(theme.inkSecondary).lineLimit(1)
            Button(action: undo) {
                Text(de("Rückgängig", en: "Undo")).underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink)
        }
        .font(Typography.text(13, .medium))
    }
}

// MARK: - Allgemein

/// One swatch per colour family: its accent on its own ground.
private struct ThemePicker: View {
    @Binding var selection: AppTheme
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppTheme.allCases, id: \.self) { family in
                Button { selection = family } label: {
                    ZStack {
                        Circle().fill(family.dark.ground)
                        Circle().fill(family.dark.signal).padding(6)
                    }
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(family == selection ? theme.ink : theme.hairline,
                                                   lineWidth: family == selection ? 2 : 1).padding(-3))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(family.name)
                // A colour dot alone says nothing to VoiceOver.
                .accessibilityLabel(family.name)
                .accessibilityAddTraits(family == selection ? .isSelected : [])
            }
        }
    }
}

private struct GeneralBlock: View {
    @Bindable var preferences: Preferences
    let launchAtLogin: LaunchAtLogin
    let history: History
    @Environment(\.theme) private var theme
    /// A smaller history (or none) asked about before anything is deleted:
    /// one click on "Off" took every dictation with it, with no way back.
    @State private var asking: Int?

    var body: some View {
        Block(title: de("Allgemein", en: "General")) {
            VStack(spacing: 0) {
                HStack {
                    Text(de("Sprache", en: "Language"))
                    Spacer()
                    Segmented(options: Language.allCases.map { (value: $0, label: $0.name) }, selection: $preferences.language)
                        .frame(width: 210)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rule()
                HStack {
                    Text(de("Farbe", en: "Colour"))
                    Spacer()
                    ThemePicker(selection: $preferences.appTheme)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rule()
                Toggle(isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) })) {
                    Text(de("Bei Anmeldung starten", en: "Start at login"))
                }
                .toggleStyle(AccentToggleStyle())
                .padding(.horizontal, 16)
                .frame(height: 48)
                .help(launchAtLogin.problem ?? "")
                Rule()
                Toggle(isOn: $preferences.pausesMedia) {
                    Text(de("Musik beim Diktieren pausieren", en: "Pause music while dictating"))
                }
                .toggleStyle(AccentToggleStyle())
                .padding(.horizontal, 16)
                .frame(height: 48)
                Rule()
                // Off: whatever was copied before comes back after pasting.
                Toggle(isOn: $preferences.keepsOnClipboard) {
                    Text(de("Text in der Zwischenablage behalten", en: "Keep text on the clipboard"))
                }
                .toggleStyle(AccentToggleStyle())
                .padding(.horizontal, 16)
                .frame(height: 48)
                Rule()
                HStack(spacing: 10) {
                    Text(de("Verlauf", en: "History"))
                    Spacer()
                    // The preference and the history change together: lowering
                    // it drops the oldest at once.
                    Segmented(
                        options: History.limits.map { (value: $0, label: Self.limitName($0)) },
                        selection: Binding(get: { preferences.historyLimit }, set: { limit in
                            if limit < history.entries.count { asking = limit } else { keep(limit) }
                        })
                    )
                    .frame(width: 230)
                    Button(de("Leeren", en: "Clear")) { asking = -1 }
                        .buttonStyle(.outlineCompact)
                        .disabled(history.entries.isEmpty)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
            }
            .font(Typography.text(15))
            .foregroundStyle(theme.ink)
            .surface(radius: 16)
        }
        .confirmationDialog(question, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button(de("Löschen", en: "Delete"), role: .destructive) {
                if let asking { asking < 0 ? history.clear() : keep(asking) }
                asking = nil
            }
            Button(de("Abbrechen", en: "Cancel"), role: .cancel) { asking = nil }
        } message: {
            Text(de("Das lässt sich nicht rückgängig machen.", en: "This cannot be undone."))
        }
    }

    private func keep(_ limit: Int) {
        preferences.historyLimit = limit
        history.limit = limit
    }

    private var question: String {
        let count = history.entries.count
        guard let asking, asking > 0 else {
            return de("Alle \(count) Diktate aus dem Verlauf löschen?", en: "Delete all \(count) dictations from the history?")
        }
        let gone = count - asking
        return de("Die ältesten \(gone) Diktate löschen?", en: "Delete the oldest \(gone) dictations?")
    }

    private static func limitName(_ limit: Int) -> String {
        switch limit {
        case 0: de("Aus", en: "Off")
        case History.keepAll: de("Alle", en: "All")
        default: "\(limit)"
        }
    }
}
