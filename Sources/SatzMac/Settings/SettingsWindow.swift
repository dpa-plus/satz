import AppKit
import SwiftUI

/// Owns the settings window.
///
/// satz normally has no Dock icon and never becomes the frontmost application.
/// While this window is open it temporarily becomes a regular app, so the window
/// comes forward, shows up in Command-Tab, and cannot get lost behind whatever
/// the user was working in. Closing it makes satz a menu bar tool again.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let content: () -> SettingsView

    init(content: @escaping () -> SettingsView) {
        self.content = content
    }

    func show() {
        let window = window ?? make()
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hosting)
        window.title = "satz"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        // The title bar melts into the petrol ground rather than sitting on
        // top of it as a grey strip.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Palette.petrol)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SettingsContent.width, height: 720))
        window.center()
        window.delegate = self
        return window
    }
}
