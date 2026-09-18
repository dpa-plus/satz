import AppKit
import SwiftUI

/// The settings window: what is missing, how to use it, and what was said.
///
/// Ordered by what a new user needs first. Setup comes before everything else
/// because nothing else works until it is done.
struct SettingsView: View {
    let setup: Setup
    let preferences: Preferences
    let history: History
    let probe: Probe
    /// Re-read the system every second while visible. Off when rendering a
    /// snapshot, so the picture shows the fixture rather than this Mac.
    var live = true

    var body: some View {
        ScrollView {
            SettingsContent(setup: setup, preferences: preferences, history: history, probe: probe)
        }
        .scrollIndicators(.never)
        .frame(width: SettingsContent.width)
        .frame(minHeight: 420, idealHeight: 720)
        .background(Palette.petrol)
        .environment(\.colorScheme, .dark)
        .task(id: live) {
            guard live else { return }
            // Permissions are granted in System Settings, which gives the app
            // no signal when it happens. Polling is the only way to notice.
            while !Task.isCancelled {
                setup.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Everything in the window, without the scroll view, so it can also be
/// rendered straight to an image.
struct SettingsContent: View {
    static let width: CGFloat = 480

    let setup: Setup
    @Bindable var preferences: Preferences
    let history: History
    let probe: Probe

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            SettingsSection(title: "Einrichtung") {
                Card {
                    KeyRow(setup: setup)
                    RowDivider()
                    MicrophoneRow(setup: setup)
                    RowDivider()
                    PasteRow(setup: setup)
                }
            }

            SettingsSection(title: "Tastenkürzel") {
                Card {
                    ShortcutRow(title: "Aufnehmen und beenden", keys: ["⌥", "Space"])
                    RowDivider()
                    ShortcutRow(title: "Abbrechen, während aufgenommen wird", keys: ["Esc"])
                }
            }

            SettingsSection(
                title: "Wortschatz",
                note: "Namen, Fachbegriffe und Schreibweisen, die satz treffen soll. Wird bei jeder Übertragung mitgeschickt und ändert nichts am Gesagten."
            ) {
                Card {
                    Group {
                        if isSnapshot {
                            // ImageRenderer cannot draw AppKit-backed controls
                            // and paints a yellow placeholder instead.
                            Text(preferences.vocabulary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField(
                                "",
                                text: $preferences.vocabulary,
                                prompt: Text("zum Beispiel: ACON, Immofanten, Prozesshub")
                                    .foregroundStyle(Palette.textTertiary),
                                axis: .vertical
                            )
                            .textFieldStyle(.plain)
                            .lineLimit(2...5)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                    .padding(14)
                }
            }

            SettingsSection(
                title: "Probe",
                note: "Vier Sekunden sprechen. Prüft Mikrofon, Schlüssel und Verbindung, ohne etwas einzufügen."
            ) {
                Card { ProbeRow(probe: probe, vocabulary: preferences.vocabulary) }
            }

            SettingsSection(
                title: "Zuletzt",
                note: "Nur bis zum Beenden, nie auf der Festplatte."
            ) {
                Card { HistoryList(history: history) }
            }
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            WaveformMark(height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("satz")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("Sprechen statt Tippen.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.orangeOnPetrol)
            }
            Spacer()
            ReadinessLabel(ready: setup.isComplete)
        }
        .padding(.top, 12)
    }
}

// MARK: - Header

private struct ReadinessLabel: View {
    let ready: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? Palette.orangeOnPetrol : Palette.textTertiary)
                .frame(width: 7, height: 7)
            Text(ready ? "Bereit" : "Einrichtung fehlt")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ready ? Palette.text : Palette.textSecondary)
        }
    }
}

// MARK: - Setup rows

/// One requirement: whether it is met, what it is for, and the way to fix it.
private struct SetupRow<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(done ? Palette.orangeOnPetrol : Palette.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct KeyRow: View {
    let setup: Setup

    @State private var editing = false
    @State private var input = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupRow(
                done: setup.hasKey,
                title: "OpenAI-Schlüssel",
                detail: setup.hasKey ? "Im Schlüsselbund gespeichert." : "Für die Übertragung an OpenAI."
            ) {
                if setup.hasKey && !editing {
                    Button("Ändern") { editing = true }.buttonStyle(.quiet)
                }
            }

            if !setup.hasKey || editing {
                entry
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .padding(.leading, 30)
            }
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Always empty when opened. The stored key is never read back
                // into a field, where it would sit in memory for no reason.
                SecureField(
                    "",
                    text: $input,
                    prompt: Text("sk-…").foregroundStyle(Palette.textTertiary)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line))
                .onSubmit(save)

                Button("Sichern", action: save)
                    .buttonStyle(.primary)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 12) {
                if editing {
                    Button("Abbrechen") { close() }.buttonStyle(.quiet)
                    Button("Schlüssel entfernen") {
                        setup.removeKey()
                        close()
                    }
                    .buttonStyle(.quiet)
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.orangeOnPetrol)
                }
            }
        }
    }

    private func save() {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try setup.store(key: key)
            close()
        } catch {
            // Said on screen rather than only logged: a key that silently
            // failed to save shows up later as a failed dictation.
            problem = error.localizedDescription
        }
    }

    private func close() {
        input = ""
        problem = nil
        editing = false
    }
}

/// A setup action. Orange only for the step to do next: with three missing
/// steps and three orange buttons, nothing reads as "start here".
private struct SetupButton: View {
    let title: String
    let isNext: Bool
    let action: () -> Void

    var body: some View {
        if isNext {
            Button(title, action: action).buttonStyle(.primary)
        } else {
            Button(title, action: action).buttonStyle(.quiet)
        }
    }
}

private struct MicrophoneRow: View {
    let setup: Setup

    /// The key comes first, so the microphone is next only once it is stored.
    private var isNext: Bool { setup.hasKey }

    var body: some View {
        SetupRow(done: setup.microphone == .allowed, title: "Mikrofon", detail: detail) {
            switch setup.microphone {
            case .allowed:
                EmptyView()
            case .notAsked:
                SetupButton(title: "Erlauben", isNext: isNext) { Task { await setup.requestMicrophone() } }
            case .denied:
                SetupButton(title: "Einstellungen", isNext: isNext) { Task { await setup.requestMicrophone() } }
            }
        }
    }

    private var detail: String {
        switch setup.microphone {
        case .allowed: "Erlaubt."
        case .notAsked: "Noch nicht gefragt."
        case .denied: "Abgelehnt. Nur in den Systemeinstellungen änderbar."
        }
    }
}

private struct PasteRow: View {
    let setup: Setup

    var body: some View {
        SetupRow(
            done: setup.canPaste,
            title: "In andere Apps einfügen",
            detail: setup.canPaste
                ? "Erlaubt."
                : "Ohne diese Freigabe landet der Text nur in der Zwischenablage."
        ) {
            if !setup.canPaste {
                SetupButton(
                    title: "Erlauben",
                    isNext: setup.hasKey && setup.microphone == .allowed
                ) { setup.requestPaste() }
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutRow: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { Keycap(label: $0) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Probe

private struct ProbeRow: View {
    let probe: Probe
    let vocabulary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: { Task { await probe.run(vocabulary: vocabulary) } }) {
                    HStack(spacing: 6) {
                        Image(systemName: probe.isRunning ? "waveform" : "mic.fill")
                        Text(label)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.primary)
                .disabled(probe.isRunning)

                if case .transcribing = probe.state {
                    ProgressView().controlSize(.small).tint(Palette.orangeOnPetrol)
                }
                Spacer()
            }

            switch probe.state {
            case .heard(let text):
                Text("„\(text)“")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.orangeOnPetrol)
            default:
                EmptyView()
            }
        }
        .padding(14)
    }

    private var label: String {
        switch probe.state {
        case .recording(let secondsLeft): "Sprechen … \(secondsLeft)"
        case .transcribing: "Schreibt …"
        default: "Probe aufnehmen"
        }
    }
}

// MARK: - History

private struct HistoryList: View {
    let history: History

    var body: some View {
        if history.entries.isEmpty {
            Text("Noch nichts diktiert.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textTertiary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { RowDivider() }
                HistoryRow(entry: entry)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: History.Entry
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .padding(.top, 2)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.quiet)
            .help("Kopieren")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
