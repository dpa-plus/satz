import SatzKit
import SwiftUI

/// The provider, as a menu. Seven names side by side do not fit a window
/// this wide (a row of buttons ran out of room at five, and two rows of them
/// did not fit Setup's narrow card at all), and a menu takes more of them
/// without growing. The dot before a name marks the provider in use, here
/// and in the list, while the name is the one being looked at (clicking one
/// only shows it). Setup has no provider in use yet, so it passes none.
struct ProviderMenu: View {
    @Binding var selection: Provider
    /// The provider dictation goes to now.
    let inUse: Provider?
    /// A field of its own, as Setup draws its inputs, rather than a bare
    /// label in a row.
    var boxed = false

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                // A picker inside the menu: the choice is one value, so the
                // menu shows a tick at the provider being looked at.
                Picker("", selection: $selection) {
                    ForEach(Provider.allCases) { provider in
                        Text(Self.title(provider, inUse: inUse)).tag(provider)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: !boxed, vertical: false)
                .frame(maxWidth: boxed ? .infinity : nil, alignment: .leading)
                .accessibilityLabel(de("Anbieter", en: "Provider"))
                .accessibilityValue(selection == inUse ? de("in Benutzung", en: "in use") : "")
        }
    }

    /// "OpenRouter · in Benutzung" in the list; the plain name where it is not.
    static func title(_ provider: Provider, inUse: Provider?) -> String {
        provider == inUse ? "\(provider.name) · \(de("in Benutzung", en: "in use"))" : provider.name
    }

    @ViewBuilder
    private var label: some View {
        let content = HStack(spacing: 8) {
            if selection == inUse { Circle().fill(theme.accent).frame(width: 7, height: 7) }
            Text(selection.name)
                .font(Typography.text(15, .semibold))
                .lineLimit(1)
            if boxed { Spacer() }
            chevron
        }
        .foregroundStyle(theme.ink)
        .contentShape(Rectangle())
        if boxed {
            content
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5))
        } else {
            content
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
    }
}

/// Microsoft's region: a menu of the regions MAI-Transcribe runs in, and
/// "Eigene Adresse …" for a resource elsewhere or under its own name, which
/// shows a field. An address wins over the region, so choosing a region
/// takes the address away: it would otherwise go on deciding, unseen.
struct MicrosoftRegionChoice: View {
    @Bindable var preferences: Preferences
    /// Setup's boxed inputs rather than Settings' rows.
    var boxed = false

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    /// The address field, shown once "Eigene Adresse …" is picked even
    /// while it is still empty.
    @State private var asking = false

    private var hasAddress: Bool { asking || !preferences.microsoftEndpoint.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(de("Region", en: "Region"))
                    .font(Typography.text(15))
                    .foregroundStyle(theme.ink)
                Spacer()
                if isSnapshot {
                    label
                } else {
                    Menu {
                        Picker("", selection: Binding(get: { hasAddress ? "" : preferences.microsoftRegion }, set: choose)) {
                            ForEach(MicrosoftSpeech.regions) { region in
                                Text(region.name).tag(region.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Button(de("Eigene Adresse …", en: "Own address …")) { asking = true }
                    } label: { label }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(de("Region", en: "Region"))
                }
            }
            .padding(.horizontal, boxed ? 12 : 16)
            .frame(height: boxed ? 42 : 48)
            .background {
                if boxed { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card) }
            }
            .overlay {
                if boxed { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5) }
            }
            if hasAddress {
                if !boxed { Rule() }
                address
                    .padding(.top, boxed ? 8 : 0)
            }
            Text(hasAddress
                 ? de("Die Adresse deiner Speech-Ressource, wie das Azure-Portal sie zeigt. Sie gilt statt der Region.",
                      en: "The address of your Speech resource, as the Azure portal shows it. It replaces the region.")
                 : de("MAI-Transcribe läuft in diesen sechs Regionen. Liegt deine Ressource woanders, hilft die eigene Adresse (dann nur Azure Speech).",
                      en: "MAI-Transcribe runs in these six regions. If your resource is elsewhere, use its own address (Azure Speech only then)."))
                .font(Typography.text(12))
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, boxed ? 2 : 16)
                .padding(.top, boxed ? 6 : 0)
                .padding(.bottom, boxed ? 0 : 10)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(hasAddress ? de("Eigene Adresse", en: "Own address")
                 : MicrosoftSpeech.regions.first { $0.id == preferences.microsoftRegion }?.name ?? preferences.microsoftRegion)
                .font(Typography.text(15))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(theme.inkOnCard)
        .contentShape(Rectangle())
    }

    private var address: some View {
        HStack(spacing: 12) {
            Text(de("Adresse", en: "Address"))
                .font(Typography.text(15))
                .foregroundStyle(theme.ink)
            Spacer()
            Group {
                if isSnapshot {
                    Text(preferences.microsoftEndpoint.isEmpty ? Self.addressPrompt : preferences.microsoftEndpoint)
                } else {
                    TextField("", text: $preferences.microsoftEndpoint, prompt: Text(Self.addressPrompt).foregroundStyle(theme.inkOnCard))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            }
            .font(Typography.mono(13))
            .foregroundStyle(theme.inkOnCard)
            .lineLimit(1)
        }
        .padding(.horizontal, boxed ? 12 : 16)
        .frame(height: boxed ? 42 : 48)
        .background {
            if boxed { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card) }
        }
        .overlay {
            if boxed { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.control, lineWidth: 1.5) }
        }
    }

    private static let addressPrompt = "https://….cognitiveservices.azure.com"

    private func choose(_ region: String) {
        guard !region.isEmpty else { return }
        asking = false
        preferences.microsoftEndpoint = ""
        preferences.microsoftRegion = region
    }
}
