import AppKit
import Observation
import SatzKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences()
    private let history = History(file: History.standardFile)
    private let discarded = Discarded()
    private let launchAtLogin = LaunchAtLogin()
    private lazy var setup = Setup(preferences: preferences)

    private var session: Session!
    private var card: CardController!
    private var shortcut: Shortcut!
    private var menuBar: MenuBarItem!
    private var settingsWindow: AppWindow!
    private var setupWindow: AppWindow!
    private var devControl: DevControl?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Typography.registerBundledFonts()
        NSApp.mainMenu = Self.mainMenu()

        if let directory = argument(after: "--snapshot") {
            try? SnapshotRenderer.write(to: directory)
            NSApp.terminate(nil)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--import-key") {
            importKey(CommandLine.arguments.dropFirst(index + 1).prefix(2).map { $0 })
            NSApp.terminate(nil)
            return
        }
        if let folder = argument(after: "--icon") {
            try? IconRenderer.write(to: folder)
            NSApp.terminate(nil)
            return
        }
        if let path = argument(after: "--hero") {
            try? HeroRenderer.write(to: path)
            NSApp.terminate(nil)
            return
        }

        session = Session(preferences: preferences, history: history, discarded: discarded)
        card = CardController(session: session, preferences: preferences)
        session.onOpen = { [weak self] in self?.card.show() }
        session.onClose = { [weak self] in self?.card.hide() }
        if let files = argument(after: "--test-audio") {
            AudioSources.testFiles = files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        if let stateFile = argument(after: "--dev-control") {
            devControl = DevControl(session: session, card: card, stateFile: URL(fileURLWithPath: stateFile))
            devControl?.toggleEye = { [weak self] in self?.preferences.showsText.toggle() }
        }
        shortcut = Shortcut(
            preferences: preferences,
            onPress: { [weak self] in self?.session.press() },
            onRelease: { [weak self] in self?.session.release() }
        )
        shortcut.start()

        settingsWindow = AppWindow(title: de("satz Einstellungen", en: "satz Settings")) { [unowned self] in
            AnyView(SettingsView(
                preferences: preferences, setup: setup, shortcut: shortcut,
                launchAtLogin: launchAtLogin, history: history
            ))
        }
        setupWindow = AppWindow(title: de("satz einrichten", en: "Set up satz")) { [unowned self] in
            AnyView(SetupView(
                preferences: preferences, setup: setup, shortcut: shortcut, history: history,
                onDone: { [weak self] in self?.setupWindow.close() }
            ))
        }

        menuBar = MenuBarItem { [unowned self] in
            AnyView(PopoverView(
                history: history, discarded: discarded, setup: setup, shortcut: shortcut, preferences: preferences,
                actions: PopoverActions(
                    restore: { [weak self] in
                        guard let self, let snapshot = discarded.take() else { return }
                        menuBar.close()
                        session.restore(snapshot)
                    },
                    openSetup: { [weak self] in self?.menuBar.close(); self?.setupWindow.show() },
                    openSettings: { [weak self] in self?.menuBar.close(); self?.settingsWindow.show() },
                    quit: { NSApp.terminate(nil) }
                )
            ))
        }
        watchAttention()
        keepSetupFresh()
        followColourFamily()

        Log.note("setup: provider=\(preferences.provider.rawValue) key=\(setup.hasKey) microphone=\(setup.microphone) paste=\(setup.canPaste)")

        // Nothing works until setup is done, and a menu bar icon alone gives a
        // new user no hint of that.
        if !setup.isComplete {
            setupWindow.show()
        }
    }

    /// Opening the app again from Finder or Spotlight shows the settings. A
    /// menu bar app otherwise appears to do nothing when relaunched.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    /// The orange dot on the menu bar icon: something needs the user.
    private func watchAttention() {
        withObservationTracking {
            // The family is read too, so the dot takes a newly picked colour.
            _ = Look.shared.family
            menuBar.needsAttention = !setup.isComplete || shortcut.status == .taken
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchAttention() }
        }
    }

    /// The app icon follows the colour family, at launch and on every change.
    private func followColourFamily() {
        withObservationTracking {
            AppIcon.apply(Look.shared.family)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followColourFamily() }
        }
    }

    /// A permission can be granted or revoked in System Settings at any time,
    /// with no notification. Cheap reads, so just look every few seconds.
    private func keepSetupFresh() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.setup.refresh()
            }
        }
    }

    /// `satz --import-key openrouter <file>`: stores the key in that file for
    /// that provider and selects it, without the key ever being typed, shown
    /// or logged. Stored by satz itself so the Keychain never asks satz for
    /// permission to read its own item.
    private func importKey(_ arguments: [String]) {
        guard arguments.count == 2, let provider = Provider(rawValue: arguments[0]),
              let contents = try? String(contentsOfFile: arguments[1], encoding: .utf8)
        else {
            Log.note("usage: satz --import-key openai|openrouter|groq|custom <file>")
            return
        }
        let key = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Secrets.store(key, for: provider)
            preferences.provider = provider
            Log.note("key imported for \(provider.rawValue)")
        } catch {
            Log.note("key import failed: \(error.localizedDescription)")
        }
    }

    /// Never shown (satz has no menu bar of its own), but macOS routes ⌘Z,
    /// ⌘X, ⌘C, ⌘V and ⌘A to text fields through it. Without it pasting a key
    /// with ⌘V did nothing.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: de("satz beenden", en: "Quit satz"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: de("Bearbeiten", en: "Edit"))
        edit.addItem(withTitle: de("Widerrufen", en: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: de("Wiederholen", en: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: de("Ausschneiden", en: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: de("Kopieren", en: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: de("Einsetzen", en: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: de("Alles auswählen", en: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    private func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
