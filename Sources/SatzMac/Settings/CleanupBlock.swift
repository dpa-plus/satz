import SatzKit
import SwiftUI

/// "Aufräumen": a language model edits the text before it is pasted. Off
/// until switched on; everything in it can be looked at and tried before
/// that. In the order of the pipeline: after Wortschatz and Ersetzungen.
struct CleanupBlock: View {
    @Bindable var preferences: Preferences
    let setup: Setup
    let store: CleanupStore
    let history: History

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        // Read when the block is drawn: the estimate follows the dictations.
        let characters = CleanupEstimate.typicalCharacters(history.spokenLengths)
        Block(title: de("Aufräumen", en: "Cleanup")) {
            VStack(alignment: .leading, spacing: 10) {
                toggle.surface(radius: 16)
                Caption(text: de("Stärke", en: "How much"))
                CleanupLevels(preferences: preferences).surface(radius: 16)
                Caption(text: de("Anbieter", en: "Provider"))
                CleanupProviderRows(preferences: preferences, setup: setup, store: store, characters: characters)
                    .surface(radius: 16)
                Caption(text: de("Ausprobieren", en: "Try it"))
                CleanupTryBox(preferences: preferences, store: store).surface(radius: 16)
            }
        }
        .task {
            guard !isSnapshot else { return }
            store.refreshApple()
            store.refreshPrices()
        }
    }

    private var toggle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $preferences.cleansText) { Text(de("Text aufräumen", en: "Clean up the text")) }
                .toggleStyle(AccentToggleStyle())
                .frame(height: 48)
            Text(Self.switchLine(for: history))
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -6)
                .padding(.bottom, 10)
            // On, but it cannot work: said in the switch's words. Dictations
            // paste the original meanwhile, with the card's notice.
            if preferences.cleansText, let missing {
                Text(missing)
                    .font(Typography.text(12))
                    .foregroundStyle(theme.accent)
                    .padding(.top, -4)
                    .padding(.bottom, 10)
            }
        }
        .font(Typography.text(15))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 16)
    }

    /// What the switch does, and where the original is afterwards. The
    /// original is only kept in the history, so with the history off there is
    /// none to come back to, and the line says so instead of promising it.
    static func switchLine(for history: History) -> String {
        history.limit > 0
            ? de("Ein Sprachmodell überarbeitet den Text, bevor satz ihn einfügt. Das Original bleibt im Verlauf.",
                 en: "A language model edits the text before satz pastes it. The original stays in the history.")
            : de("Ein Sprachmodell überarbeitet den Text, bevor satz ihn einfügt. Der Verlauf ist aus: das Original wird nicht aufbewahrt.",
                 en: "A language model edits the text before satz pastes it. History is off: the original is not kept.")
    }

    private var missing: String? {
        if let provider = CleanupReadiness.message(store.missing(preferences.cleanupProvider, preferences, hasKey: setup.hasKey(account:))) {
            return provider
        }
        if preferences.cleanupLevel == .custom, preferences.cleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return de("Erst den Prompt eintragen", en: "Enter the prompt first")
        }
        return nil
    }
}

/// A small heading over a surface inside a block, like the history's days.
private struct Caption: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(Typography.text(12, .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(theme.inkSecondary)
            .padding(.leading, 10)
            .padding(.top, 6)
    }
}

// MARK: - Stärke

private struct CleanupLevels: View {
    @Bindable var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            ForEach(CleanupLevel.allCases) { level in
                if level != CleanupLevel.allCases.first { Rule() }
                LevelRow(level: level, selected: preferences.cleanupLevel == level) {
                    preferences.chooseCleanupLevel(level)
                }
            }
            Rule()
            if preferences.cleanupLevel == .custom {
                CustomPromptEditor(preferences: preferences)
            } else {
                PromptPreview(prompt: CleanupPrompt.system(preferences.cleanupLevel, vocabulary: preferences.words))
            }
        }
    }
}

/// A radio row with a title and what the level does, in one line.
private struct LevelRow: View {
    let level: CleanupLevel
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RadioMark(selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(level.title())
                    .font(Typography.text(15))
                    .foregroundStyle(theme.ink)
                Text(level.line())
                    .font(Typography.text(12))
                    .foregroundStyle(theme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// The exact system prompt satz sends for the level, so nothing is hidden.
private struct PromptPreview: View {
    let prompt: String
    @Environment(\.theme) private var theme
    @Environment(\.showsCleanupPrompt) private var startsOpen
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? startsOpen
        VStack(alignment: .leading, spacing: 8) {
            Button { open = !isOpen } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(de("Prompt ansehen", en: "Show prompt"))
                        .font(Typography.text(13, .medium))
                }
                .foregroundStyle(theme.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Text(prompt)
                    .font(Typography.mono(11.5))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The own prompt: six lines to start, growing to twelve, then it scrolls.
/// Saved when the field is left and at most a second after typing, so
/// nothing typed is lost when the window closes.
private struct CustomPromptEditor: View {
    @Bindable var preferences: Preferences
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var draft = ""
    @State private var saving: Task<Void, Never>?
    @FocusState private var focused: Bool

    private static let line: CGFloat = 19

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The hidden text sizes the editor: as tall as what is typed,
            // between six and twelve lines.
            Text(shown + "\n")
                .font(Typography.text(14))
                .lineSpacing(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 6 * Self.line + 16, maxHeight: 12 * Self.line + 16, alignment: .top)
                .opacity(isSnapshot ? 1 : 0)
                .foregroundStyle(theme.ink)
                .overlay {
                    if !isSnapshot {
                        TextEditor(text: $draft)
                            .font(Typography.text(14))
                            .lineSpacing(2)
                            .foregroundStyle(theme.ink)
                            .scrollContentBackground(.hidden)
                            .scrollIndicators(.automatic)
                            .focused($focused)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 8)
                    }
                }
                .clipped()
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))
            Text(de("Der diktierte Text wird angehängt, dein Wortschatz auch.",
                    en: "The dictated text is added after it, and so is your vocabulary."))
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
        }
        .padding(12)
        .onAppear { draft = preferences.cleanupPrompt }
        .onChange(of: draft) { saveSoon() }
        .onChange(of: focused) { _, now in if !now { save() } }
        .onDisappear(perform: save)
    }

    private var shown: String { isSnapshot ? preferences.cleanupPrompt : draft }

    private func saveSoon() {
        guard saving == nil else { return }
        saving = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        saving?.cancel()
        saving = nil
        if preferences.cleanupPrompt != draft { preferences.cleanupPrompt = draft }
    }
}

// MARK: - Anbieter

/// The cleanup provider as a menu, the way the transcription's looks: the
/// dot marks the one in use, the name is the one shown.
private struct CleanupProviderMenu: View {
    @Binding var selection: CleanupProvider
    let inUse: CleanupProvider
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                Picker("", selection: $selection) {
                    ForEach(CleanupProvider.menu) { provider in
                        Text(provider == inUse ? "\(provider.name) · \(de("in Benutzung", en: "in use"))" : provider.name).tag(provider)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(de("Anbieter fürs Aufräumen", en: "Cleanup provider"))
                .accessibilityValue(selection == inUse ? de("in Benutzung", en: "in use") : "")
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if selection == inUse { Circle().fill(theme.accent).frame(width: 7, height: 7) }
            Text(selection.name)
                .font(Typography.text(15, .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(theme.ink)
        .contentShape(Rectangle())
    }
}

/// Clicking a provider only shows it; "… benutzen" switches. The rows are
/// the shown provider's: key, address, model and what it costs.
private struct CleanupProviderRows: View {
    @Bindable var preferences: Preferences
    let setup: Setup
    let store: CleanupStore
    let characters: Double
    @Environment(\.theme) private var theme

    var body: some View {
        let shown = store.shown(preferences)
        let inUse = preferences.cleanupProvider
        VStack(spacing: 0) {
            HStack {
                CleanupProviderMenu(selection: Binding(get: { shown }, set: { store.looking = $0 == inUse ? nil : $0 }), inUse: inUse)
                Spacer(minLength: 8)
                if shown == inUse {
                    Text(de("In Benutzung", en: "In use"))
                        .font(Typography.text(13))
                        .foregroundStyle(theme.inkSecondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            if shown != inUse { switchRow(shown: shown, inUse: inUse) }
            Rule()
            if let account = shown.keyAccount {
                KeyRow(setup: setup, account: account,
                       shared: shown.sharesKey == nil ? nil : de("Derselbe Schlüssel wie für die Spracherkennung.",
                                                                 en: "The same key as for speech recognition."),
                       linksToPage: true)
                Rule()
            }
            if shown.hasAddress {
                FieldRow(label: de("Adresse", en: "Address"),
                         text: Binding(get: { preferences.cleanupAddress(for: shown) }, set: { preferences.setCleanupAddress($0, for: shown) }),
                         prompt: shown == .azure ? "https://….openai.azure.com" : (shown.defaultAddress.isEmpty ? "https://…/v1" : shown.defaultAddress))
                Rule()
            }
            CleanupModelRow(preferences: preferences, store: store, provider: shown, characters: characters)
        }
        .onChange(of: preferences.cleanupProvider) { _, now in if store.looking == now { store.looking = nil } }
    }

    private func switchRow(shown: CleanupProvider, inUse: CleanupProvider) -> some View {
        HStack(spacing: 12) {
            Text(CleanupSwitchWording.goesTo(inUse))
                .font(Typography.text(13))
                .foregroundStyle(theme.inkSecondary)
            Spacer(minLength: 8)
            if let missing = CleanupReadiness.message(store.missing(shown, preferences, hasKey: setup.hasKey(account:))) {
                Text(missing)
                    .font(Typography.text(13))
                    .foregroundStyle(theme.inkSecondary)
            } else {
                Button(CleanupSwitchWording.button(shown)) {
                    preferences.cleanupProvider = shown
                    store.looking = nil
                }
                .buttonStyle(.accentCompact)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

/// The model: a menu of what the provider offers, each with what it adds to
/// a dictation in seconds and dollars, and "Anderes Modell …" for an id typed
/// by hand. Azure's deployment and an own server's model are typed.
private struct CleanupModelRow: View {
    @Bindable var preferences: Preferences
    let store: CleanupStore
    let provider: CleanupProvider
    let characters: Double

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var typing = false
    /// Saved on Return or when the field is left, as in the transcription's.
    @State private var draft = ""
    @FocusState private var idFocused: Bool

    private static let other = "\u{0}other"

    var body: some View {
        let list = store.models(provider, address: preferences.cleanupAddress(for: provider))
        let id = store.modelID(provider, preferences)
        let current = list.first { $0.id == id }
        let model = store.model(provider, preferences)
        VStack(alignment: .leading, spacing: 0) {
            switch provider {
            case .azure, .custom:
                FieldRow(label: provider == .azure ? de("Bereitstellung", en: "Deployment") : de("Modell", en: "Model"),
                         text: Binding(get: { preferences.cleanupModel(for: provider) }, set: { preferences.setCleanupModel($0, for: provider) }),
                         prompt: provider == .azure ? "gpt-6-luna" : de("Modell-ID", en: "Model ID"))
            case .apple:
                HStack(spacing: 12) {
                    Text(de("Modell", en: "Model")).font(Typography.text(15)).foregroundStyle(theme.ink)
                    Spacer()
                    Text("Apple Intelligence").font(Typography.text(15)).foregroundStyle(theme.inkOnCard)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
            default:
                menuRow(list: list, current: current)
            }
            Text(facts(model))
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .padding(.top, -6)
            if provider.family != .apple, provider != .azure, provider != .custom, typing || (current == nil && !id.isEmpty) {
                Rule()
                idField
            }
        }
        .onChange(of: provider) {
            draft = preferences.cleanupModel(for: provider)
            typing = false
            idFocused = false
        }
        .onChange(of: typing) { _, now in if now { Task { idFocused = true } } }
        .onChange(of: idFocused) { _, focused in if !focused { commit() } }
        .onAppear { draft = preferences.cleanupModel(for: provider) }
        .onDisappear { typing = false }
        // Again for each address shown. Awaited here, so showing another one
        // (or closing Settings) stops the ask of the one before; and what it
        // answers anyway is kept for its own address only (`CleanupStore.refreshInstalled`).
        .task(id: "\(provider.rawValue) \(preferences.cleanupAddress(for: provider))") {
            guard !isSnapshot, provider == .ollama || provider == .lmStudio else { return }
            await store.refreshInstalled(provider, address: preferences.cleanupAddress(for: provider))
        }
    }

    private func menuRow(list: [CleanupModel], current: CleanupModel?) -> some View {
        HStack(spacing: 12) {
            Text(de("Modell", en: "Model"))
                .font(Typography.text(15))
                .foregroundStyle(theme.ink)
            Spacer()
            if isSnapshot {
                label(current)
            } else {
                Menu {
                    Picker("", selection: selection(current)) {
                        ForEach(list) { model in
                            Text(CleanupWording.title(model, estimate(model))).tag(model.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button(de("Anderes Modell …", en: "Other model …")) {
                        draft = preferences.cleanupModel(for: provider)
                        typing = true
                    }
                } label: { label(current) }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(de("Modell fürs Aufräumen", en: "Cleanup model"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var idField: some View {
        HStack(spacing: 12) {
            Text(de("Modell-ID", en: "Model ID"))
                .font(Typography.text(15))
                .foregroundStyle(theme.ink)
            Spacer()
            if isSnapshot {
                Text(preferences.cleanupModel(for: provider))
            } else {
                TextField("", text: $draft, prompt: Text(provider.defaultModel).foregroundStyle(theme.inkOnCard))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .focused($idFocused)
                    .onSubmit { commit() }
                    // Escape keeps the model there was.
                    .onExitCommand {
                        draft = preferences.cleanupModel(for: provider)
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

    private func selection(_ current: CleanupModel?) -> Binding<String> {
        Binding(
            get: { current?.id ?? Self.other },
            set: { id in
                guard id != Self.other else { return }
                typing = false
                idFocused = false
                preferences.setCleanupModel(id, for: provider)
                draft = id
            }
        )
    }

    private func commit() {
        let id = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { preferences.setCleanupModel(id, for: provider) }
        draft = preferences.cleanupModel(for: provider)
        typing = false
    }

    private func label(_ current: CleanupModel?) -> some View {
        HStack(spacing: 6) {
            // Ollama's models are named by their id; "Ollama gemma4:4b" says it twice.
            Text(current.map { provider == .ollama || provider == .lmStudio ? $0.name : "\($0.maker) \($0.name)" }
                 ?? (store.modelID(provider, preferences).isEmpty ? "–" : de("Anderes", en: "Other")))
                .font(Typography.text(15))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(theme.inkOnCard)
        .contentShape(Rectangle())
    }

    private func estimate(_ model: CleanupModel) -> CleanupEstimate {
        store.estimate(model, provider: provider, preferences: preferences, characters: characters)
    }

    /// Under the model: what it adds to a dictation, then what to know about it.
    private func facts(_ model: CleanupModel) -> String {
        switch provider {
        case .apple:
            if let message = store.appleState.message() { return message }
            return CleanupWording.facts(model, estimate(model), note: de(
                "Kostenlos, bleibt auf dem Mac. Kleines Modell: beantwortet manchmal Fragen im Text oder übersetzt; satz fügt dann meist das Original ein.",
                en: "Free, stays on this Mac. A small model: it sometimes answers questions in the text or translates; satz then mostly pastes the original."))
        case .ollama, .lmStudio:
            if store.isNotRunning(provider, address: preferences.cleanupAddress(for: provider)) {
                return provider == .ollama ? de("Ollama läuft nicht. ollama.com", en: "Ollama is not running. ollama.com")
                                           : de("LM Studio läuft nicht.", en: "LM Studio is not running.")
            }
            return CleanupWording.facts(model, estimate(model), note: de(CleanupCatalog.onThisComputer.de, en: CleanupCatalog.onThisComputer.en))
        case .azure:
            return CleanupWording.facts(model, estimate(model), note: model.note(),
                                        priceNote: de("Preis je nach Bereitstellung.", en: "Price depends on the deployment."))
        default:
            return CleanupWording.facts(model, estimate(model), note: model.note())
        }
    }
}

// MARK: - Ausprobieren

/// A sample to clean up with what is shown, before switching anything on.
/// Its time counts as a measurement for that model.
private struct CleanupTryBox: View {
    @Bindable var preferences: Preferences
    let store: CleanupStore
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var sample = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if isSnapshot {
                    Text(text)
                        .lineLimit(3, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    TextField("", text: $sample, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .textFieldStyle(.plain)
                        .disabled(store.trying)
                }
            }
            .font(Typography.text(14))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))
            HStack(spacing: 10) {
                Button { store.tryOut(text, preferences) } label: {
                    HStack(spacing: 6) {
                        if store.trying { Spinner() }
                        Text(store.trying ? de("Abbrechen", en: "Cancel") : de("Ausprobieren", en: "Try"))
                    }
                }
                .buttonStyle(.outlineCompact)
                .disabled(!store.trying && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            if let tried = store.tried, !store.trying {
                result(tried)
            }
        }
        .padding(12)
        .onAppear { if sample.isEmpty { sample = CleanupSample.text(for: preferences.spokenLanguage) } }
        .onChange(of: store.tryInput(text, preferences)) { store.discardStaleTry(text, preferences) }
    }

    private var text: String { sample.isEmpty ? CleanupSample.text(for: preferences.spokenLanguage) : sample }

    @ViewBuilder
    private func result(_ tried: CleanupStore.Tried) -> some View {
        let result = tried.result
        VStack(alignment: .leading, spacing: 4) {
            if let cleaned = result.cleaned {
                Text(cleaned)
                    .font(Typography.text(14))
                    .foregroundStyle(result.failure == nil ? theme.ink : theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if result.failure == nil {
                // Nothing worth sending: it would be pasted as it is.
                Text(result.text)
                    .font(Typography.text(14))
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
            }
            if let line = CleanupWording.tryLine(seconds: result.seconds, dollars: result.dollars) {
                Text(line)
                    .font(Typography.text(12))
                    .foregroundStyle(theme.inkSecondary)
            }
            if result.failure == .rejected {
                Text(de("Verworfen: sah nicht nach deinem Text aus. satz würde das Original einfügen.",
                        en: "Rejected: did not look like your text. satz would paste the original."))
                    .font(Typography.text(12))
                    .foregroundStyle(theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = result.failure {
                Text(failure.short())
                    .font(Typography.text(12, .medium))
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// The cleanup prompt shown open at first, for a picture of it.
    @Entry var showsCleanupPrompt = false
}
