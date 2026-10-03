import AppKit
import Observation
import SatzKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences()
    private let history = History()
    private let outbox = Outbox()
    private let launchAtLogin = LaunchAtLogin()
    private lazy var setup = Setup(preferences: preferences)

    private var pill: PillController!
    private var dictation: Dictation!
    private var shortcut: Shortcut!
    private var menuBar: MenuBarItem!
    private var settingsWindow: AppWindow!
    private var setupWindow: AppWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Typography.registerBundledFonts()

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

        pill = PillController(
            onCancel: { [weak self] in self?.dictation.cancel() },
            onRetry: { [weak self] in self?.dictation.retry() }
        )
        dictation = Dictation(pill: pill, preferences: preferences, history: history, outbox: outbox)
        shortcut = Shortcut(
            preferences: preferences,
            onPress: { [weak self] in self?.dictation.press() },
            onRelease: { [weak self] in self?.dictation.release() }
        )
        shortcut.start()

        settingsWindow = AppWindow { [unowned self] in
            AnyView(SettingsView(
                preferences: preferences, setup: setup, shortcut: shortcut,
                launchAtLogin: launchAtLogin, history: history
            ))
        }
        setupWindow = AppWindow { [unowned self] in
            AnyView(SetupView(
                preferences: preferences, setup: setup, shortcut: shortcut, history: history,
                onDone: { [weak self] in self?.setupWindow.close() }
            ))
        }

        menuBar = MenuBarItem { [unowned self] in
            AnyView(PopoverView(
                history: history, outbox: outbox, setup: setup, shortcut: shortcut, preferences: preferences,
                actions: PopoverActions(
                    retry: { [weak self] in self?.menuBar.close(); self?.dictation.retry() },
                    discard: { [weak self] in self?.dictation.discard() },
                    openSetup: { [weak self] in self?.menuBar.close(); self?.setupWindow.show() },
                    openSettings: { [weak self] in self?.menuBar.close(); self?.settingsWindow.show() },
                    quit: { NSApp.terminate(nil) }
                )
            ))
        }
        watchAttention()
        keepSetupFresh()

        Log.note("setup: provider=\(preferences.provider.rawValue) key=\(setup.hasKey) microphone=\(setup.microphone) paste=\(setup.canPaste)")

        // Nothing works until setup is done, and a menu bar icon alone gives a
        // new user no hint of that.
        if !setup.isComplete {
            setupWindow.show()
        }

        if CommandLine.arguments.contains("--demo") {
            pill.show()
            DemoDriver.run(on: pill.recording)
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
            menuBar.needsAttention = outbox.pending != nil || !setup.isComplete || shortcut.status == .taken
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchAttention() }
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

    private func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
