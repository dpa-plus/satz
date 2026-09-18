import AppKit
import SatzKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let setup = Setup.current()
    private let preferences = Preferences()
    private let history = History()
    private let probe = Probe()

    private var pill: PillController?
    private var dictation: Dictation?
    private var menuBar: MenuBar?
    private var hotKey: HotKey?
    private var settings: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = argument(after: "--snapshot") {
            try? SnapshotRenderer.write(to: directory)
            NSApp.terminate(nil)
            return
        }

        if let path = argument(after: "--hero") {
            try? HeroRenderer.write(to: path)
            NSApp.terminate(nil)
            return
        }

        let pill = PillController(onCancel: { [weak self] in self?.dictation?.cancel() })
        self.pill = pill
        dictation = Dictation(pill: pill, preferences: preferences, history: history)

        settings = SettingsWindow { [setup, preferences, history, probe] in
            SettingsView(setup: setup, preferences: preferences, history: history, probe: probe)
        }

        let shortcut = HotKey.Combination.optionSpace
        menuBar = MenuBar(
            shortcut: shortcut.display,
            onToggle: { [weak self] in Task { await self?.dictation?.toggle() } },
            onSettings: { [weak self] in self?.settings?.show() }
        )
        installHotKey(shortcut)

        Log.note("setup: key=\(setup.hasKey) microphone=\(setup.microphone) paste=\(setup.canPaste)")

        // Nothing works until setup is done, and a menu bar icon alone gives a
        // new user no hint of that. Show them what is missing.
        if !setup.isComplete {
            settings?.show()
        }

        if CommandLine.arguments.contains("--demo") {
            pill.show()
            DemoDriver.run(on: pill.recording)
        }
    }

    /// Clicking the app again, from Finder or Spotlight, should show something.
    /// A menu bar app otherwise appears to do nothing when relaunched.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show()
        return true
    }

    private func installHotKey(_ combination: HotKey.Combination) {
        do {
            hotKey = try HotKey(combination) { [weak self] in
                Task { await self?.dictation?.toggle() }
            }
            Log.note("shortcut registered: \(combination.display)")
        } catch {
            // Surfaced rather than swallowed: the app still works from the menu
            // bar, but the key the user reaches for would do nothing and say
            // nothing about why.
            Log.note("shortcut NOT registered: \(error.localizedDescription)")
            menuBar?.report(shortcutProblem: error.localizedDescription)
        }
    }

    private func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
