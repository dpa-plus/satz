import AppKit
import Observation
import SatzKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences()
    /// In test mode next to the state file: a test that clears or trims the
    /// history must not touch the user's.
    private lazy var history = History(
        file: LaunchMode.current.stateFile.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("history.json") }
            ?? History.standardFile,
        limit: preferences.historyLimit
    )
    private let discarded = Discarded()
    private let launchAtLogin = LaunchAtLogin()
    private lazy var setup = Setup(preferences: preferences)

    private var session: Session!
    private var card: CardController!
    private var shortcut: Shortcut!
    private var menuBar: MenuBarItem!
    /// History and settings, one window.
    private var mainWindow: AppWindow!
    private let navigation = MainNavigation()
    private let models = ModelStore()
    private var setupWindow: AppWindow!
    private var devControl: DevControl?
    private let mediaPause = MediaPause()

    /// A dictation tool is only useful if it is there when the Mac starts, so
    /// starting at login is on from the first launch. Only once: switched off
    /// in the settings, it stays off.
    private func startAtLoginByDefault() {
        let key = "startAtLoginDefaulted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !launchAtLogin.isEnabled { launchAtLogin.set(true) }
        Log.note("start at login: \(launchAtLogin.isEnabled ? "on" : "could not be switched on")")
    }

    private func quitOtherCopies() {
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "plus.dpa.satz")
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return }
        Log.note("quitting \(others.count) other satz copy")
        for other in others { other.terminate() }
        // One that does not quit when asked is stopped.
        Task {
            try? await Task.sleep(for: .seconds(2))
            for other in others where !other.isTerminated { other.forceTerminate() }
        }
    }

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
        if let path = argument(after: "--showcase") {
            try? SnapshotRenderer.writeShowcase(to: path)
            NSApp.terminate(nil)
            return
        }
        // A test flag without its value: never run as the user's own satz
        // (that would quit theirs) with half a test setup.
        if case .invalid(let why) = LaunchMode.current {
            Log.note("not started: \(why)")
            NSApp.terminate(nil)
            return
        }
        // One satz at a time. Two copies (an old one still running after an
        // update, or one opened from Downloads next to the one in
        // Applications) both heard the shortcut, and every text was pasted
        // twice. The newest one takes over. A test copy leaves the real one be.
        if LaunchMode.current.stateFile == nil {
            quitOtherCopies()
            startAtLoginByDefault()
        }

        session = Session(preferences: preferences, history: history, discarded: discarded)
        card = CardController(session: session, preferences: preferences)
        session.onOpen = { [weak self] in self?.card.show() }
        session.onRecord = { [weak self] in self?.mediaPause.dictationStarted() }
        session.onClose = { [weak self] in self?.card.hide(); self?.mediaPause.dictationEnded() }
        // Never in test mode, where it would pause the user's own music,
        // unless a test asks for it.
        mediaPause.isOn = { [weak self] in
            guard let self else { return false }
            return preferences.pausesMedia && (LaunchMode.current.stateFile == nil || CommandLine.arguments.contains("--test-media"))
        }
        if let files = argument(after: "--test-audio") {
            AudioSources.testFiles = files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        if let stateFile = LaunchMode.current.stateFile {
            devControl = DevControl(session: session, card: card, stateFile: URL(fileURLWithPath: stateFile))
            devControl?.toggleEye = { [weak self] in self?.preferences.showsText.toggle() }
            devControl?.spoken = { [weak self] in self?.preferences.spokenLanguage ?? .german }
            devControl?.use = { [weak self] model in
                self?.preferences.localModel = model
                self?.preferences.provider = .local
                LocalModels.shared.warmUp(model, language: self?.preferences.spokenLanguage ?? .german)
            }
            Log.note("test mode: models in \(LocalModels.root.path)\(LocalModels.canChangeFiles ? "" : ", shared with the real satz: no downloads")")
            // A test copy running next to the real satz must not answer the
            // user's own shortcut or Escape: it did, and ate their dictations.
            session.takesEscape = false
        }
        shortcut = Shortcut(
            preferences: preferences,
            onPress: { [weak self] in self?.session.press() },
            onRelease: { [weak self] in self?.session.release() }
        )
        if devControl == nil { shortcut.start() }

        mainWindow = AppWindow(
            title: self.navigation.page == .history ? de("satz Verlauf", en: "satz History") : de("satz Einstellungen", en: "satz Settings"),
            startsWithoutFocus: true
        ) { [unowned self] in
            AnyView(MainView(navigation: navigation, history: history, preferences: preferences, setup: setup,
                             shortcut: shortcut, launchAtLogin: launchAtLogin, models: models))
        }
        navigation.onChange = { [weak self] in self?.mainWindow.retitle() }
        setupWindow = AppWindow(title: de("satz einrichten", en: "Set up satz"), freshEachTime: true) { [unowned self] in
            AnyView(SetupView(
                preferences: preferences, setup: setup, shortcut: shortcut, history: history, models: models,
                onDone: { [weak self] in self?.setupWindow.close() }
            ))
        }

        menuBar = MenuBarItem { [unowned self] in
            // Read as the menu opens, before it takes the keyboard: from then
            // on the app behind it has no focused field to report, and Insert
            // stayed grey everywhere. The field cannot change while the menu
            // is open (a click elsewhere closes it), so once is enough.
            let target = Session.frontmostOtherApp()
            let place = FocusedField.capture(in: target)
            let canInsert = FocusedField.isEditable(in: target)
            return AnyView(PopoverView(
                history: history, discarded: discarded, setup: setup, shortcut: shortcut, preferences: preferences,
                actions: PopoverActions(
                    // Taken only when it can come back: taking it while
                    // dictating threw it away for good.
                    canRestore: { [weak self] in self?.session.canRestore ?? false },
                    restore: { [weak self] in
                        guard let self, session.canRestore, let snapshot = discarded.take() else { return }
                        menuBar.close()
                        session.restore(snapshot)
                    },
                    openSetup: { [weak self] in self?.menuBar.close(); self?.setupWindow.show() },
                    openSettings: { [weak self] in self?.menuBar.close(); self?.show(.settings) },
                    openHistory: { [weak self] in self?.menuBar.close(); self?.show(.history) },
                    canInsert: canInsert,
                    insert: { [weak self] text in
                        guard let self else { return }
                        menuBar.close()
                        // A test copy never types into the user's apps.
                        guard devControl == nil else {
                            Log.note("insert from the menu into \(target?.localizedName ?? "?"): test mode, not pasted")
                            return
                        }
                        let outcome = Paster.deliver(text, into: target, window: place.window, field: place.field,
                                                     keepsOnClipboard: preferences.keepsOnClipboard)
                        Log.note("insert from the menu into \(target?.localizedName ?? "?"): \(outcome == .pasted ? "sent ⌘V" : "clipboard only")")
                    },
                    quit: { NSApp.terminate(nil) }
                )
            ))
        }
        Paster.closeMenus = { [weak self] in self?.menuBar.close() }
        session.menuIsOpen = { [weak self] in self?.menuBar.isOpen ?? false }
        session.closeMenu = { [weak self] in self?.menuBar.close() }
        devControl?.open = { [weak self] which in
            switch which {
            case "settings": self?.show(.settings)
            case "setup": self?.setupWindow.show()
            case "history": self?.show(.history)
            case "close": self?.mainWindow.close(); self?.setupWindow.close()
            default: self?.menuBar.open()
            }
        }
        watchAttention()
        keepSetupFresh()
        followColourFamily()

        Log.note("setup: provider=\(preferences.provider.rawValue) key=\(setup.hasKey) microphone=\(setup.microphone) paste=\(setup.canPaste)")
        LocalModels.shared.isWanted = { [weak self] model in
            self?.preferences.provider == .local && self?.preferences.model == model
        }
        // Download, then use: a download never switches the model by itself,
        // unless the one in use is not on this Mac (the first local model,
        // or one that was removed). Setup relies on it.
        LocalModels.shared.onDownloaded = { [weak self] model in
            guard let self, LocalModels.shared.takesOver(model, inUse: preferences.localModel, language: preferences.spokenLanguage)
            else { return }
            Log.note("local: \(model) is now the model in use, \(preferences.localModel) is not on this Mac")
            preferences.localModel = model
        }
        LocalModels.shared.vocabulary = { [weak self] in self?.preferences.transcriberSettings.vocabulary ?? [] }
        LocalModels.shared.toldChoice = { [weak self] in self?.preferences.toldLanguage }
        LocalModels.shared.isDictating = { [weak self] in
            switch self?.session.phase {
            case .starting?, .listening?, .paused?, .finishing?: true
            default: false
            }
        }
        // A model on this Mac is loaded now, not at the first dictation.
        if !preferences.provider.needsKey {
            let model = preferences.model, spoken = preferences.spokenLanguage
            LocalModels.shared.warmUp(model, language: spoken)
            Task { await LocalModels.shared.check(model, language: spoken) }
        }

        // Nothing works until setup is done, and a menu bar icon alone gives a
        // new user no hint of that. A test copy opens no window by itself
        // (`setup` does): a fresh models folder left its setup unfinished,
        // and the window would land on the user's screen.
        if !setup.isComplete && devControl == nil {
            setupWindow.show()
        }
    }

    /// Opening the app again from Finder or Spotlight shows the history, or
    /// the setup while it is unfinished. A menu bar app otherwise appears to
    /// do nothing when relaunched.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !setup.isComplete {
            setupWindow.show()
        } else if mainWindow.isVisible {
            // Already open: brought forward as it is, a half-typed setting included.
            mainWindow.show()
        } else {
            show(.history)
        }
        return true
    }

    private func show(_ page: MainNavigation.Page) {
        navigation.page = page
        mainWindow.show()
    }

    /// Quitting with a window open: the app the user came from gets the focus
    /// back, not whichever app macOS picks.
    func applicationWillTerminate(_ notification: Notification) {
        mediaPause.quitting()
        AppWindow.handBack()
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

        // ⌘W, as in every other Mac window.
        let file = NSMenu(title: de("Ablage", en: "File"))
        file.addItem(withTitle: de("Fenster schließen", en: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        main.addItem(fileItem)

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
