import AppKit
import SwiftUI

/// A normal window for the things done rarely: setting up, and settings.
///
/// satz normally has no Dock icon and never becomes the frontmost application.
/// While one of these is open it becomes a regular app, so the window comes
/// forward, shows up in Command-Tab, and cannot get lost behind whatever the
/// user was working in. When the last one closes it steps back again, and
/// hands the focus back to the app the user came from.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {

    private static var open = 0
    /// The app that was in front before satz came forward. Without handing
    /// back to it, macOS picks some other app when satz steps back: WhatsApp,
    /// for one, came forward every time the settings closed.
    private static var cameFrom: NSRunningApplication?

    private var window: NSWindow?
    /// Whether this window is in `open`. Its visibility said no while satz
    /// was hidden (Hide Others), and the window was counted twice.
    private var counted = false
    private let title: () -> String
    private let content: () -> AnyView
    private let startsWithoutFocus: Bool
    private let freshEachTime: Bool

    /// The content sets its own width; the window follows its preferred size.
    /// The title is not drawn, but names the window in Mission Control, the
    /// Window menu and for VoiceOver.
    /// Read each time the window opens, so it follows a language change.
    ///
    /// `startsWithoutFocus`: no field holds the keyboard when the window opens.
    /// Otherwise AppKit hands it to the first field (in the settings: the
    /// model), where typing meant for somewhere else quietly changes it.
    ///
    /// `freshEachTime`: the content is built anew whenever the window opens.
    /// The setup reopened at the step it was closed on, not at what is missing now.
    init(title: @autoclosure @escaping () -> String, startsWithoutFocus: Bool = false, freshEachTime: Bool = false,
         content: @escaping () -> AnyView) {
        self.title = title
        self.startsWithoutFocus = startsWithoutFocus
        self.freshEachTime = freshEachTime
        self.content = content
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            window = make()
        } else if freshEachTime && !counted {
            window?.contentViewController = hosting()
        }
        window?.title = title()
        // Each time satz comes forward, not only the first: Settings opened
        // from Safari, then Notes, then back to satz, should close to Notes.
        let front = NSWorkspace.shared.frontmostApplication
        if front != nil && front != .current { Self.cameFrom = front }
        if Self.open == 0 {
            NSApp.setActivationPolicy(.regular)
        }
        let opening = !counted
        if opening {
            counted = true
            Self.open += 1
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if opening && startsWithoutFocus, let window {
            // After AppKit has picked its first field, which happens as the
            // window becomes key.
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }

    func close() {
        window?.close()
    }

    /// Reads the title again, for a window whose content changed its subject.
    func retitle() {
        window?.title = title()
    }

    func windowWillClose(_ notification: Notification) {
        guard counted else { return }
        counted = false
        Self.open = max(0, Self.open - 1)
        if Self.open == 0 { Self.stepBack() }
    }

    /// Hands the focus to the app the user came from. Only the active app may,
    /// so this runs while satz still is.
    @discardableResult
    static func handBack() -> Bool {
        guard let app = cameFrom else { return false }
        cameFrom = nil
        guard NSApp.isActive, !app.isTerminated, !app.isHidden else { return false }
        NSApp.yieldActivation(to: app)
        app.activate()
        return true
    }

    /// Back to a menu bar app. The order matters: an app that drops its Dock
    /// icon while it is still the active one leaves macOS to pick the next app
    /// itself, and it picked WhatsApp. So the focus is handed on first, and
    /// satz steps back once it has gone.
    private static func stepBack() {
        guard handBack() else {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        Task { @MainActor in
            for _ in 0..<20 where NSApp.isActive {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if open == 0 { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func hosting() -> NSViewController {
        let hosting = NSHostingController(rootView: content().themed())
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentViewController: hosting())
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        // The title bar melts into the ground rather than sitting on top of it
        // as a grey strip.
        window.titlebarAppearsTransparent = true
        window.title = title()
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
