import SatzKit
import SwiftUI

struct UpdateNotice: View {
    let updates: UpdateState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 18, weight: .medium))
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typography.text(15))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.ink)
            if updates.stage == .downloading || updates.stage == .extracting {
                if let progress = updates.progress { ProgressView(value: progress).tint(theme.accent) }
                else { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 12) {
                if updates.stage == .available {
                    Button(updates.informationOnly ? de("Details", en: "Details") : de("Update und Neustart", en: "Update and restart")) {
                        updates.install()
                    }.buttonStyle(.accent)
                    Button(de("Später", en: "Later")) { updates.later() }.buttonStyle(.plain)
                } else if updates.stage == .failed {
                    Button(de("Erneut versuchen", en: "Try again")) { updates.check() }.buttonStyle(.outlineCompact)
                    Button(de("Schließen", en: "Dismiss")) { updates.later() }.buttonStyle(.plain)
                } else if updates.stage == .current {
                    Button(de("Schließen", en: "Dismiss")) { updates.later() }.buttonStyle(.plain)
                } else if updates.stage == .checking || updates.stage == .waiting || updates.stage == .downloading {
                    Button(de("Abbrechen", en: "Cancel")) { updates.cancel() }.buttonStyle(.plain)
                }
            }
            .font(Typography.text(14))
            .foregroundStyle(theme.inkSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch updates.stage {
        case .available: de("satz \(updates.version) ist verfügbar", en: "satz \(updates.version) is available")
        case .checking: de("Sucht nach Updates…", en: "Checking for updates…")
        case .downloading: de("Update wird geladen…", en: "Downloading update…")
        case .extracting: de("Update wird vorbereitet…", en: "Preparing update…")
        case .waiting: de("Aktualisiert nach deinem Diktat", en: "Will update after your dictation")
        case .restarting: de("satz startet neu…", en: "Restarting satz…")
        case .current: de("satz ist aktuell", en: "satz is up to date")
        case .failed: de("Update nicht möglich. Bitte erneut versuchen.", en: "Couldn’t update. Please try again.")
        case .idle: ""
        }
    }
}
