import SatzKit
import SwiftUI

/// The models for "Lokal" as Handy shows them: "Your models", the ones on
/// this Mac with the one in use first, and "Available models", everything
/// else. Each is a card with what it is good for, how accurate and how fast
/// it is, the languages it hears and its size. Clicking an available card
/// downloads it, clicking one of yours uses it. A download never switches
/// to the model by itself, unless the model in use is not on this Mac. In
/// Settings and in Setup alike.
struct LocalModelCards: View {
    @Bindable var preferences: Preferences
    let store: ModelStore
    /// Setup's narrow card: the bars go under the text.
    var narrow = false

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let local = LocalModels.shared
        let current = preferences.localModel
        let spoken = preferences.spokenLanguage
        let supported = local.supported
        let sections = LocalCatalog.sections(supported: supported, hasApple: Self.hasApple, current: current) { id in
            // Once its files are complete it is one of yours, even while it
            // is still being prepared or timed.
            local.isOnMac(id) || local.measuring.contains(id) || local.state(of: id, language: spoken) == .preparing
        }
        let recommended = LocalCatalog.recommended(supported: supported)
        VStack(alignment: .leading, spacing: 8) {
            heading(de("Deine Modelle", en: "Your models"))
            if sections.yours.isEmpty {
                Text(de("Noch keins. Klick unten ein Modell an, dann lädt satz es.", en: "None yet. Click a model below and satz downloads it."))
                    .font(Typography.text(13))
                    .foregroundStyle(theme.inkSecondary)
                    .padding(.bottom, 4)
            }
            ForEach(sections.yours, id: \.self) { id in
                ModelCard(id: id, preferences: preferences, benchmarks: store.benchmarks, yours: true,
                          recommended: false, narrow: narrow)
            }
            // Canary and Apple's listen for one language: chosen here, where it matters.
            if Self.listensForOneLanguage(current) {
                SpokenRow(preferences: preferences, model: current)
            }
            if !sections.available.isEmpty {
                heading(de("Verfügbare Modelle", en: "Available models"))
                    .padding(.top, 8)
                ForEach(sections.available, id: \.self) { id in
                    ModelCard(id: id, preferences: preferences, benchmarks: store.benchmarks, yours: false,
                              recommended: id == recommended, narrow: narrow)
                }
            }
            Text(de("Läuft auf diesem Mac, ohne Internet und kostenlos.", en: "Runs on this Mac, offline and free."))
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
                .padding(.top, 4)
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

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Typography.text(13, .semibold))
            .foregroundStyle(theme.inkSecondary)
    }

    static func listensForOneLanguage(_ id: String) -> Bool {
        id == ModelCatalog.apple || LocalCatalog.model(id)?.sherpa?.isToldTheLanguage == true
    }

    private static var hasApple: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// "Gesprochen auf": the one language Canary and Apple's listen for.
/// Apple's: German or English, the spoken language everything else goes
/// by. Canary: its own four, kept apart, so Spanish for Canary leaves
/// Whisper, the replacements and Apple's on German or English.
private struct SpokenRow: View {
    @Bindable var preferences: Preferences
    let model: String
    @Environment(\.theme) private var theme

    var body: some View {
        // Side by side where the four fit, the choice under the label where not.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                choice
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                choice
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var label: some View {
        Text(de("Gesprochen auf", en: "Spoken in"))
            .font(Typography.text(14))
            .foregroundStyle(theme.ink)
            .fixedSize()
    }

    @ViewBuilder
    private var choice: some View {
        if let entry = LocalCatalog.model(model), let codes = entry.toldLanguages {
            Segmented(options: codes.map { (value: $0, label: LocalLanguages.name($0)) },
                      selection: Binding(get: { entry.told(choice: preferences.toldLanguage, spoken: preferences.spokenLanguage) ?? "" },
                                         set: { preferences.toldLanguage = $0 }))
                .fixedSize()
        } else {
            Segmented(options: Language.allCases.map { (value: $0, label: $0.name) }, selection: $preferences.spokenLanguage)
                .fixedSize()
        }
    }
}

/// One model, as Handy's ModelCard: name and badges over one sentence, the
/// accuracy and speed bars beside them, then languages, size and Delete;
/// a download's progress or a spinner line when something is under way.
private struct ModelCard: View {
    let id: String
    @Bindable var preferences: Preferences
    let benchmarks: LocalBenchmarks
    /// In "Your models": clicking uses it rather than downloading it.
    let yours: Bool
    let recommended: Bool
    let narrow: Bool

    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var local: LocalModels { LocalModels.shared }
    private var model: LocalCatalog.Model? { LocalCatalog.model(id) }
    private var spoken: Language { preferences.spokenLanguage }
    private var state: LocalModels.State { local.state(of: id, language: spoken) }
    private var isApple: Bool { id == ModelCatalog.apple }
    private var measuring: Bool { local.measuring.contains(id) }
    /// Only while Lokal is the provider: looked at from another one, no
    /// local model is in use, and clicking one switches to Lokal.
    private var inUse: Bool { preferences.provider == .local && preferences.localModel == id }
    private static let chip = Chip.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if narrow {
                description
                bars
            } else {
                HStack(alignment: .center, spacing: 16) {
                    description.frame(maxWidth: .infinity, alignment: .leading)
                    bars
                }
            }
            Rule()
            bottomRow
            if let status = statusLine { status }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(border, lineWidth: 1.5))
        .opacity(isBlocked ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: click)
        .onHover { hovering = $0 }
        .help(cardHelp)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(action != nil ? .isButton : [])
        .accessibilityLabel(model?.name ?? id)
    }

    // MARK: - Clicking

    private enum Action { case download, use }

    /// What a click on the card does now, if anything.
    private var action: Action? {
        switch state {
        case .missing, .failed: .download
        case .ready where yours && !inUse: .use
        default: nil
        }
    }

    /// One download at a time: the other cards wait for it.
    private var isBlocked: Bool { action == .download && local.isDownloading }

    private func click() {
        guard !isBlocked else { return }
        switch action {
        case .download?: local.download(id, language: spoken)
        case .use?:
            // An explicit choice: the model, and Lokal if it was only looked at.
            preferences.localModel = id
            preferences.provider = .local
        case nil: break
        }
    }

    private var cardHelp: String {
        if isBlocked { return de("Erst wenn der andere Download fertig ist", en: "Once the other download is done") }
        switch action {
        case .download?:
            if isApple { return de("Klicken lädt Apples Sprachpaket", en: "Click to download Apple's language pack") }
            return de("Klicken lädt das Modell auf diesen Mac", en: "Click to download the model to this Mac")
        case .use?: return de("Klicken benutzt dieses Modell", en: "Click to use this model")
        case nil: return ""
        }
    }

    private var fill: Color {
        if inUse { return theme.accent.opacity(0.08) }
        return hovering && action != nil && !isBlocked ? theme.hover : theme.card
    }

    private var border: Color {
        if inUse { return theme.accent }
        return hovering && action != nil && !isBlocked ? theme.accent.opacity(0.6) : theme.hairline
    }

    // MARK: - Top

    private var description: some View {
        VStack(alignment: .leading, spacing: 3) {
            FlowLayout(spacing: 7, lineSpacing: 4) {
                Text(model?.name ?? id)
                    .font(model == nil ? Typography.mono(13) : Typography.text(15, .semibold))
                    .foregroundStyle(theme.ink)
                if inUse { Badge(text: de("Aktiv", en: "Active"), filled: true) }
                if recommended { Badge(text: de("Empfohlen", en: "Recommended"), filled: false) }
            }
            if let summary = model?.summary, !summary.isEmpty {
                Text(summary)
                    .font(Typography.text(13))
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var bars: some View {
        if let model {
            let speed = LocalScores.speed(of: id, measured: local.speeds, chip: Self.chip, benchmarks: benchmarks)
            let layout = narrow ? AnyLayout(HStackLayout(spacing: 18)) : AnyLayout(VStackLayout(alignment: .trailing, spacing: 6))
            layout {
                ScoreBar(label: de("Genauigkeit", en: "Accuracy"), value: model.accuracy, narrow: narrow)
                    .help(accuracyHelp)
                if canMeasure {
                    Button { local.measure(id, language: spoken) } label: {
                        ScoreBar(label: de("Tempo", en: "Speed"), value: speed.score, narrow: narrow)
                    }
                    .buttonStyle(.plain)
                    .help(speedHelp(speed.source) + " " + de("Klicken misst neu.", en: "Click to measure again."))
                } else {
                    ScoreBar(label: de("Tempo", en: "Speed"), value: speed.score, narrow: narrow)
                        .help(speedHelp(speed.source))
                }
            }
        }
    }

    /// The speed bar times the model again: the number changes with the
    /// word list, and a run can go wrong, and neither must stick.
    private var canMeasure: Bool { !isApple && local.isOnMac(id) && state == .ready && !measuring }

    private var accuracyHelp: String {
        if let errors = LocalFacts.errors(english: benchmarks.english[id], german: benchmarks.german[id]) {
            let source = de("Falsche Wörter laut Argmax' Messung genau dieser Fassung: Englisch auf LibriSpeech und Earnings-22, Deutsch auf Common Voice 17.",
                            en: "Wrong words per Argmax's test of this exact build: English on LibriSpeech and Earnings-22, German on Common Voice 17.")
            let noGerman = benchmarks.german[id] == nil
                ? " " + de("Auf Deutsch hat Argmax diese Fassung nicht gemessen.", en: "Argmax did not test this build in German.") : ""
            return "\(errors). \(source)\(noGerman)"
        }
        return de("Grobe Einschätzung nach dem, was über das Modell veröffentlicht ist. satz misst die Genauigkeit nicht selbst.",
                  en: "A rough rating from what is published about the model. satz does not measure accuracy itself.")
    }

    private func speedHelp(_ source: LocalScores.SpeedSource) -> String {
        switch source {
        case .measured(let speed):
            let date = LocalFacts.date(speed.measured)
            return LocalFacts.speed(speed.secondsPer10, estimated: false) + ", "
                + de("gemessen auf diesem Mac am \(date).", en: "measured on this Mac on \(date).")
        case .estimated(let seconds, let chip, let scaledBy):
            let text = LocalFacts.speed(seconds, estimated: true) + ", "
            if let reference = scaledBy.map({ LocalCatalog.model($0)?.name ?? $0 }) {
                return text + de("geschätzt nach Argmax' Messung auf einem \(chip), angepasst an \(reference) auf diesem Mac.",
                                 en: "estimated from Argmax's measurement on an \(chip), adjusted to \(reference) on this Mac.")
            }
            return text + de("geschätzt nach Argmax' Messung auf einem \(chip).", en: "estimated from Argmax's measurement on an \(chip).")
        case .rated:
            if isApple { return de("Grobe Einschätzung.", en: "A rough rating.") }
            return de("Grobe Einschätzung, bis satz das Modell nach dem Laden auf diesem Mac misst.",
                      en: "A rough rating, until satz times the model on this Mac after the download.")
        }
    }

    // MARK: - Bottom

    private var bottomRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Wraps in the narrow Setup card rather than losing a language.
            if let languages = model?.languages {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 11, weight: .medium))
                    Text(languages.text()).fixedSize(horizontal: false, vertical: true)
                }
                .help(languages.list() ?? "")
            }
            Spacer(minLength: 8)
            if let size = sizeText {
                HStack(spacing: 4) {
                    Image(systemName: yours ? "internaldrive" : "arrow.down.circle").font(.system(size: 11, weight: .medium))
                    Text(size).monospacedDigit()
                }
                .fixedSize()
                .help(yours ? de("Was das Modell auf diesem Mac belegt", en: "What the model takes up on this Mac")
                            : de("Was der Download wiegt", en: "What the download weighs"))
            }
            if canDelete {
                Button { local.remove(id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                        Text(de("Löschen", en: "Delete"))
                    }
                    .foregroundStyle(theme.ink)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(de("Legt das Modell in den Papierkorb", en: "Moves the model to the Trash"))
            }
        }
        .font(Typography.text(12))
        .foregroundStyle(theme.inkSecondary)
    }

    private var sizeText: String? {
        if isApple { return de("Eingebaut", en: "Built in") }
        return model?.bytes.map { LocalFacts.size($0) }
    }

    private var canDelete: Bool {
        guard yours, !isApple, local.isOnMac(id), !measuring else { return false }
        switch state {
        case .ready, .failed: return true
        default: return false
        }
    }

    // MARK: - Under way

    private var statusLine: AnyView? {
        if measuring { return AnyView(busy(de("Tempo wird gemessen", en: "Measuring speed"))) }
        switch state {
        case .downloading(let fraction):
            return AnyView(VStack(alignment: .leading, spacing: 5) {
                ProgressBar(fraction: fraction)
                HStack(spacing: 8) {
                    Text(de("Lädt", en: "Downloading") + " \(Int((fraction * 100).rounded())) %")
                        .font(Typography.text(12))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkSecondary)
                    Spacer()
                    if !isApple {
                        Button(de("Abbrechen", en: "Cancel")) { local.cancel(id) }
                            .buttonStyle(.outlineCompact)
                    }
                }
            })
        case .preparing:
            let whisper = model?.engine == .whisperKit
            return AnyView(busy(whisper ? de("Wird vorbereitet", en: "Getting ready") : de("Wird geladen", en: "Loading"))
                .help(whisper ? de("macOS richtet das Modell einmal für diesen Mac ein, ein bis zwei Minuten.",
                                   en: "macOS sets the model up for this Mac once, a minute or two.") : ""))
        case .failed(let why):
            return AnyView(Text(de("Laden fehlgeschlagen. Klicken versucht es nochmal.", en: "Download failed. Click to try again."))
                .font(Typography.text(12))
                .foregroundStyle(theme.ink)
                .help(why))
        case .unavailable(let why):
            return AnyView(Text(why).font(Typography.text(12)).foregroundStyle(theme.ink))
        case .missing, .ready:
            return nil
        }
    }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 6) {
            Spinner()
            Text(label).font(Typography.text(12)).foregroundStyle(theme.inkSecondary)
        }
    }
}

/// A small label in a capsule after a model's name.
private struct Badge: View {
    let text: String
    /// "Active" is filled, "Recommended" only outlined.
    let filled: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            if filled { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            Text(text).font(Typography.text(11, .semibold))
        }
        .foregroundStyle(filled ? theme.accentLabel : theme.ink)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(filled ? theme.accent : .clear))
        .overlay(Capsule().strokeBorder(filled ? .clear : theme.accent, lineWidth: 1.2))
    }
}

/// "Genauigkeit" or "Tempo" and a short bar, filled from 0 to 1.
private struct ScoreBar: View {
    let label: String
    let value: Double
    let narrow: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
                .frame(width: narrow ? nil : 76, alignment: .trailing)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(theme.hairline)
                Capsule().fill(theme.accent).frame(width: max(4, 64 * min(1, max(0, value))))
            }
            .frame(width: 64, height: 6)
        }
        .contentShape(Rectangle())
    }
}
