import SatzKit
import SwiftUI

/// satz's one window: the history and the settings, one click apart. Two
/// windows for them meant a second one popping up beside the first.
struct MainView: View {
    let navigation: MainNavigation
    let history: History
    let preferences: Preferences
    let setup: Setup
    let shortcut: Shortcut
    let launchAtLogin: LaunchAtLogin
    let models: ModelStore
    let cleanups: CleanupStore

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                tab(de("Verlauf", en: "History"), .history, key: "1")
                tab(de("Einstellungen", en: "Settings"), .settings, key: "2")
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 12)
            // Every label is read again when the language changes. The settings
            // do it inside their scroll view, which stays, and so keeps its
            // place: the language and colour pickers sit at the bottom.
            .id(preferences.lookKey)

            switch navigation.page {
            case .history:
                HistoryView(history: history, preferences: preferences)
                    .id(preferences.lookKey)
            case .settings:
                SettingsView(preferences: preferences, setup: setup, shortcut: shortcut,
                             launchAtLogin: launchAtLogin, history: history, models: models, cleanups: cleanups)
            }
        }
        .frame(width: 560, height: 760, alignment: .topLeading)
        .background(theme.ground)
        .focusEffectDisabled()
    }

    /// The page names are the headings: the open one in ink, the other one
    /// quieter, both clickable, and ⌘1 / ⌘2 switch between them.
    private func tab(_ title: String, _ page: MainNavigation.Page, key: KeyEquivalent) -> some View {
        let open = navigation.page == page
        return Button { navigation.page = page } label: {
            Text(title)
                .font(Typography.display(26))
                .foregroundStyle(open ? theme.ink : theme.inkSecondary.opacity(0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(open ? [.isHeader, .isSelected] : [.isHeader])
    }
}

/// Which page of the window is showing; the menu bar and opening the app
/// choose it.
@MainActor
@Observable
final class MainNavigation {
    enum Page { case history, settings }
    var page: Page = .history {
        didSet { onChange() }
    }
    /// The window's title follows the page, for Mission Control and VoiceOver.
    @ObservationIgnored var onChange: () -> Void = {}
}
