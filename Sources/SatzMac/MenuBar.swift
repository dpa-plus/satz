import AppKit
import SatzKit

/// The status item and its menu. satz has no window, so this is the whole
/// interface apart from the pill.
@MainActor
final class MenuBar {

    private let item: NSStatusItem
    private let onToggle: () -> Void

    init(shortcut: String?, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "satz")
        item.menu = buildMenu(shortcut: shortcut)
    }

    /// Shown when the shortcut could not be registered, so the user is not left
    /// wondering why the key does nothing.
    func report(shortcutProblem: String) {
        item.button?.toolTip = shortcutProblem
        item.menu?.item(at: 0)?.title = shortcutProblem
        item.menu?.item(at: 0)?.isEnabled = false
    }

    private func buildMenu(shortcut: String?) -> NSMenu {
        let menu = NSMenu()

        let record = NSMenuItem(
            title: shortcut.map { "Aufnehmen  (\($0))" } ?? "Aufnehmen",
            action: #selector(toggle),
            keyEquivalent: ""
        )
        record.target = self
        menu.addItem(record)

        menu.addItem(.separator())

        let key = NSMenuItem(title: "OpenAI-Schlüssel …", action: #selector(editKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)

        let access = NSMenuItem(
            title: "Einfügen erlauben …",
            action: #selector(requestAccessibility),
            keyEquivalent: ""
        )
        access.target = self
        menu.addItem(access)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "satz beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func toggle() {
        onToggle()
    }

    @objc private func requestAccessibility() {
        Paster.requestAccessibility()
    }

    @objc private func editKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI-Schlüssel"
        alert.informativeText = """
            Wird im Schlüsselbund gespeichert, nicht in einer Datei.
            Leer lassen und sichern entfernt den Schlüssel.
            """
        alert.addButton(withTitle: "Sichern")
        alert.addButton(withTitle: "Abbrechen")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-…"
        field.stringValue = Secrets.read() ?? ""
        alert.accessoryView = field

        // The app is an accessory, so it has to come forward for its own alert
        // to be reachable, and step back afterwards.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(field)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if entered.isEmpty {
            Secrets.remove()
            Log.note("key removed")
        } else {
            do {
                try Secrets.store(entered)
                Log.note("key stored")
            } catch {
                Log.note("key not stored: \(error.localizedDescription)")
            }
        }
    }
}
