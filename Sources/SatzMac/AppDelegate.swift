import AppKit
import SatzKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var pill: PillController?
    private var dictation: Dictation?
    private var menuBar: MenuBar?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = argument(after: "--snapshot") {
            try? SnapshotRenderer.write(to: path)
            NSApp.terminate(nil)
            return
        }

        let pill = PillController(onCancel: { [weak self] in self?.dictation?.cancel() })
        let dictation = Dictation(pill: pill)
        self.pill = pill
        self.dictation = dictation

        let shortcut = HotKey.Combination.optionSpace
        menuBar = MenuBar(shortcut: shortcut.display) { [weak self] in
            Task { await self?.dictation?.toggle() }
        }
        installHotKey(shortcut)

        if CommandLine.arguments.contains("--demo") {
            pill.show()
            DemoDriver.run(on: pill.recording)
        }
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
