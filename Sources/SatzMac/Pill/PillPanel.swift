import AppKit
import SwiftUI

/// The window the pill lives in.
///
/// It floats above other applications and never takes keyboard focus, so the
/// text field you were typing in stays focused and the transcript can be
/// pasted straight back into it. A normal window would steal first responder
/// the moment it appeared and there would be nowhere to paste.
@MainActor
final class PillPanel: NSPanel {

    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // the SwiftUI capsule draws its own
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // Follow the user across desktops and into full-screen apps: dictation
        // is something you do wherever you happen to be typing.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none

        contentView = content
    }

    /// Never. Taking key status would move focus away from the user's text field.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the pill centred near the bottom of the screen holding the mouse,
    /// which is where the user is already looking.
    func reposition() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = contentView?.fittingSize ?? frame.size
        setContentSize(size)

        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 96
        )
        setFrameOrigin(origin)
    }

    func present() {
        reposition()
        orderFrontRegardless()
    }
}
