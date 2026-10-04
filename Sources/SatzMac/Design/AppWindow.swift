import AppKit
import SwiftUI

/// A normal window for the things done rarely: setting up, and settings.
///
/// satz normally has no Dock icon and never becomes the frontmost application.
/// While one of these is open it becomes a regular app, so the window comes
/// forward, shows up in Command-Tab, and cannot get lost behind whatever the
/// user was working in. When the last one closes it steps back again.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {

    private static var open = 0

    private var window: NSWindow?
    private let title: String
    private let content: () -> AnyView
    var onClose: (() -> Void)?

    /// The content sets its own width; the window follows its preferred size.
    /// The title is not drawn, but names the window in Mission Control, the
    /// Window menu and for VoiceOver.
    init(title: String, content: @escaping () -> AnyView) {
        self.title = title
        self.content = content
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            window = make()
        }
        if Self.open == 0 { NSApp.setActivationPolicy(.regular) }
        if window?.isVisible == false { Self.open += 1 }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open = max(0, Self.open - 1)
        if Self.open == 0 { NSApp.setActivationPolicy(.accessory) }
        onClose?()
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: content().themed())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        // The title bar melts into the ground rather than sitting on top of it
        // as a grey strip.
        window.titlebarAppearsTransparent = true
        window.title = title
        window.titleVisibility = .hidden
        window.backgroundColor = Self.ground
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        return window
    }

    /// Sand or petrol, resolved live when the Mac switches appearance.
    private static let ground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(MainActor.assumeIsolated { Theme.dark.ground })
            : NSColor(MainActor.assumeIsolated { Theme.light.ground })
    }
}
