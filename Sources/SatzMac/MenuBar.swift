import AppKit

/// The status item and its menu. Kept to what is used daily; everything that is
/// set once lives in the settings window.
@MainActor
final class MenuBar {

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let onToggle: () -> Void
    private let onSettings: () -> Void

    init(shortcut: String?, onToggle: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onSettings = onSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "satz")
        // Off, so the informational line added by report(shortcutProblem:)
        // stays greyed out instead of being re-enabled by AppKit.
        menu.autoenablesItems = false
        build(shortcut: shortcut)
        item.menu = menu
    }

    /// Shown when the shortcut could not be registered. Added as its own line:
    /// the record item stays usable, because the menu is exactly how the app
    /// still works without the shortcut.
    func report(shortcutProblem: String) {
        item.button?.toolTip = shortcutProblem
        let note = NSMenuItem(title: shortcutProblem, action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.insertItem(note, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    private func build(shortcut: String?) {
        let record = NSMenuItem(
            title: shortcut.map { "Aufnehmen  (\($0))" } ?? "Aufnehmen",
            action: #selector(toggle),
            keyEquivalent: ""
        )
        record.target = self
        menu.addItem(record)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "satz beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggle() {
        onToggle()
    }

    @objc private func openSettings() {
        onSettings()
    }
}
