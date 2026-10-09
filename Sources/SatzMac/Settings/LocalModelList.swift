import SatzKit
import SwiftUI

/// The models for "Lokal", as a list to pick from: each with its size, how
/// fast it runs here and how many words it gets wrong, and the one thing to
/// do with it. Download, then use: loading one never switches to it, unless
/// the model in use is not on this Mac. In Settings and in Setup alike.
struct LocalModelList: View {
    @Bindable var preferences: Preferences
    let store: ModelStore

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let local = LocalModels.shared
        let current = preferences.localModel
        let ids = LocalCatalog.rows(supported: local.supported, hasApple: Self.hasApple, current: current, isOnMac: local.isOnMac)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if index > 0 { Rule() }
                LocalModelItem(id: id, preferences: preferences, benchmarks: store.benchmarks)
                // Apple's listens for one language: chosen here, where it matters.
                if id == ModelCatalog.apple, current == ModelCatalog.apple {
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
            Rule()
            Text(de("Läuft auf diesem Mac, ohne Internet und kostenlos.", en: "Runs on this Mac, offline and free."))
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .task {
            guard !isSnapshot else { return }
            store.refreshBenchmarks()
            local.refreshSupport()
        }
        .task(id: preferences.spokenLanguage) {
            if !isSnapshot { await local.check(ModelCatalog.apple, language: preferences.spokenLanguage) }
        }
    }

    private static var hasApple: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// One model: its name over its facts, and on the right what can be done
/// with it now.
private struct LocalModelItem: View {
    let id: String
    @Bindable var preferences: Preferences
    let benchmarks: LocalBenchmarks

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The right side is kept short (longer states go to the second
            // line), and the name wraps rather than losing a word: cut short
            // in the narrow Setup card, the full-size Turbo lost "volle", the
            // one word that tells it from the row above.
            HStack(spacing: 8) {
                title
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                actions
                    .fixedSize()
            }
            .frame(minHeight: 28)
            // A model typed in by hand has no facts at all.
            let shown = self.pieces
            if !shown.isEmpty { facts(shown) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The name, and its tag after it in the same text, so a narrow card
    /// wraps the tag rather than squeezing the name.
    private var title: Text {
        guard let model = LocalCatalog.model(id) else {
            return Text(id).font(Typography.mono(13)).foregroundStyle(theme.ink)
        }
        let name = Text(model.name).font(Typography.text(15, .medium)).foregroundStyle(theme.ink)
        guard let tag = model.tag else { return name }
        return name + Text("  " + tag).font(Typography.text(12)).foregroundStyle(theme.inkSecondary)
    }

    private var local: LocalModels { LocalModels.shared }
    private var state: LocalModels.State { local.state(of: id, language: spoken) }
    private var spoken: Language { preferences.spokenLanguage }
    /// Only while Lokal is the provider: shown while another one is in use,
    /// every row offers Benutzen, which switches to Lokal as well.
    private var inUse: Bool { preferences.provider == .local && preferences.localModel == id }
    private var isApple: Bool { id == ModelCatalog.apple }

    // MARK: - Right side

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if local.measuring.contains(id) {
                busy(de("Tempo wird gemessen", en: "Measuring speed"))
            } else {
                switch state {
                case .missing:
                    Button(de("Laden", en: "Download")) { local.download(id, language: spoken) }
                        .buttonStyle(.accentCompact)
                        .disabled(local.isDownloading)
                        .help(local.isDownloading ? de("Erst wenn der andere Download fertig ist", en: "Once the other download is done") : "")
                case .downloading(let fraction):
                    ProgressBar(fraction: fraction)
                        .frame(width: 96)
                    Text("\(Int((fraction * 100).rounded())) %")
                        .font(Typography.text(12))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkSecondary)
                        .frame(width: 40, alignment: .trailing)
                case .preparing:
                    busy(de("Wird vorbereitet", en: "Getting ready"))
                        .help(de("macOS richtet das Modell einmal für diesen Mac ein, ein bis zwei Minuten.",
                                 en: "macOS sets the model up for this Mac once, a minute or two."))
                case .ready:
                    if inUse {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent)
                            Text(de("In Benutzung", en: "In use")).font(Typography.text(13, .semibold)).foregroundStyle(theme.ink)
                        }
                    } else {
                        Button(de("Benutzen", en: "Use")) {
                            preferences.localModel = id
                            preferences.provider = .local
                        }
                            .buttonStyle(.accentCompact)
                    }
                    if !isApple {
                        Button(de("Entfernen", en: "Remove")) { local.remove(id) }
                            .buttonStyle(.outlineCompact)
                            .help(de("Legt das Modell in den Papierkorb", en: "Moves the model to the Trash"))
                    }
                // Both say why on the second line.
                case .unavailable:
                    EmptyView()
                case .failed(let why):
                    Button(de("Nochmal", en: "Try again")) { local.download(id, language: spoken) }
                        .buttonStyle(.outlineCompact)
                        .disabled(local.isDownloading)
                        .help(why)
                }
            }
        }
    }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 6) {
            Spinner()
            Text(label).font(Typography.text(13)).foregroundStyle(theme.inkSecondary)
        }
    }

    // MARK: - Second line

    /// Size, speed, errors: each its own piece, so a narrow card wraps
    /// between them, and each says where its number comes from.
    private func facts(_ pieces: [Piece]) -> some View {
        FlowLayout(spacing: 3, lineSpacing: 1) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                piece.view(last: index == pieces.count - 1, theme: theme)
            }
        }
        .font(Typography.text(12))
        .foregroundStyle(theme.inkSecondary)
        .help(hasSpeed || isApple ? "" : de("Das Tempo misst satz nach dem Laden", en: "satz measures the speed after the download"))
    }

    private var hasSpeed: Bool {
        local.speeds[id] != nil || (!onMac && benchmarks.estimate(id, chip: Self.chip, measured: local.speeds) != nil)
    }

    private var onMac: Bool { !isApple && local.isOnMac(id) }

    private static let chip = Chip.current

    private var pieces: [Piece] {
        // A model that cannot run here says why, and nothing else matters.
        if case .unavailable(let why) = state { return [.status(why, help: "")] }
        var pieces: [Piece] = []
        // Here rather than beside the button, where it squeezed the name.
        if case .failed(let why) = state { pieces.append(.status(de("Laden fehlgeschlagen", en: "Download failed"), help: why)) }
        if isApple {
            pieces.append(.text(de("Eingebaut", en: "Built in"), help: de("Teil von macOS 26", en: "Part of macOS 26")))
        } else if let bytes = LocalCatalog.model(id)?.bytes {
            pieces.append(.text(LocalFacts.size(bytes), help: de("Was der Download wiegt", en: "What the download weighs")))
        }
        let measure = { local.measure(id, language: spoken) }
        let canMeasure = onMac && !local.measuring.contains(id) && state == .ready
        if let speed = local.speeds[id] {
            let text = LocalFacts.speed(speed.secondsPer10, estimated: false)
            if canMeasure, speed.isCurrent(chip: Self.chip, version: LocalModels.version) {
                // The number itself measures again: it changes with the word
                // list, and a run can go wrong, and neither must stick.
                pieces.append(.quietButton(text, help: measuredHelp(speed) + ". " + de("Klicken misst neu.", en: "Click to measure again."),
                                           action: measure))
            } else {
                pieces.append(.text(text, help: measuredHelp(speed)))
                // From another Mac or another satz: says little about this one.
                if canMeasure { pieces.append(.button(measureLabel, help: measureHelp, action: measure)) }
            }
        } else if onMac {
            if canMeasure { pieces.append(.button(measureLabel, help: measureHelp, action: measure)) }
        } else if let estimate = benchmarks.estimate(id, chip: Self.chip, measured: local.speeds) {
            let help = if let reference = estimate.scaledBy.map({ LocalCatalog.model($0)?.name ?? $0 }) {
                de("Geschätzt nach Argmax' Messung auf einem \(estimate.chip), angepasst an \(reference) auf diesem Mac",
                   en: "Estimated from Argmax's measurement on an \(estimate.chip), adjusted to \(reference) on this Mac")
            } else {
                de("Geschätzt nach Argmax' Messung auf einem \(estimate.chip)",
                   en: "Estimated from Argmax's measurement on an \(estimate.chip)")
            }
            pieces.append(.text(LocalFacts.speed(estimate.secondsPer10, estimated: true), help: help))
        }
        if let errors = LocalFacts.errors(english: benchmarks.english[id], german: benchmarks.german[id]) {
            pieces.append(.text(errors, help: errorsHelp))
        }
        return pieces
    }

    private var measureLabel: String { de("Tempo messen", en: "Measure speed") }
    private var measureHelp: String { de("Misst auf diesem Mac, wie schnell das Modell schreibt", en: "Times the model on this Mac") }

    private func measuredHelp(_ speed: LocalSpeed) -> String {
        let date = LocalFacts.date(speed.measured)
        if speed.isCurrent(chip: Self.chip, version: LocalModels.version) {
            return de("Auf diesem Mac gemessen, am \(date)", en: "Measured on this Mac, on \(date)")
        }
        return de("Gemessen am \(date) mit satz \(speed.version) auf einem \(speed.machine)",
                  en: "Measured on \(date) with satz \(speed.version) on an \(speed.machine)")
    }

    private var errorsHelp: String {
        let source = de("Falsche Wörter laut Argmax' Messung genau dieser Fassung: Englisch auf LibriSpeech und Earnings-22, Deutsch auf Common Voice 17.",
                        en: "Wrong words per Argmax's test of this exact build: English on LibriSpeech and Earnings-22, German on Common Voice 17.")
        guard benchmarks.german[id] == nil else { return source }
        return source + " " + de("Auf Deutsch hat Argmax diese Fassung nicht gemessen.", en: "Argmax did not test this build in German.")
    }

    /// One fact on the second line.
    private enum Piece {
        case text(String, help: String)
        /// What keeps the model from working: first, and in the ink colour.
        case status(String, help: String)
        case button(String, help: String, action: () -> Void)
        /// A fact that does something when clicked, as quiet as the others
        /// until the pointer is on it.
        case quietButton(String, help: String, action: () -> Void)

        /// With its " · " attached, so a wrapped line never starts with one.
        @MainActor @ViewBuilder
        func view(last: Bool, theme: Theme) -> some View {
            let separator = last ? "" : " ·"
            switch self {
            case .text(let text, let help):
                Text(text + separator).help(help)
            case .status(let text, let help):
                HStack(spacing: 0) {
                    Text(text).foregroundStyle(theme.ink).help(help)
                    Text(separator)
                }
            case .button(let label, let help, let action):
                HStack(spacing: 0) {
                    Button(action: action) { Text(label).underline().foregroundStyle(theme.ink) }
                        .buttonStyle(.plain)
                        .help(help)
                    Text(separator)
                }
            case .quietButton(let label, let help, let action):
                HStack(spacing: 0) {
                    QuietLink(label: label, action: action).help(help)
                    Text(separator)
                }
            }
        }
    }
}

/// Text that is a button, underlined only under the pointer.
private struct QuietLink: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { Text(label).underline(hovering) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
    }
}
