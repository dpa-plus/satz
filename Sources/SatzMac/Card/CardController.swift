import AppKit
import SwiftUI

/// Owns the card's window: shows it near the bottom of the screen and grows
/// it upward, so the strip with the buttons stays exactly where it was.
@MainActor
final class CardController {

    private let session: Session
    private let preferences: Preferences
    private var panel: CardPanel?

    init(session: Session, preferences: Preferences) {
        self.session = session
        self.preferences = preferences
    }

    func show() {
        let panel = panel ?? make()
        self.panel = panel
        if !panel.isVisible {
            panel.placeAtBottom()
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func make() -> CardPanel {
        let panel = CardPanel()
        let view = CardView(session: session, preferences: preferences) { [weak panel] size in
            panel?.resize(to: size)
        }
        let hosting = NSHostingView(rootView: view.themed())
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.resize(to: hosting.fittingSize)
        return panel
    }
}

/// Floats above everything, follows the user across desktops, and takes the
/// keyboard only when the user clicks into the text. Pressing a button on
/// the card leaves the app they were typing in focused.
final class CardPanel: NSPanel {

    /// Where the bottom edge sits, kept while the card grows.
    private var bottom: CGFloat?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CardView.width, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Centred near the bottom of the screen holding the mouse, which is where
    /// the user is already looking.
    func placeAtBottom() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        bottom = visible.minY + 96
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: bottom ?? frame.minY))
    }

    /// Taller or shorter with the text, bottom edge fixed.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: bottom ?? frame.minY)
        setFrame(NSRect(origin: origin, size: size), display: true)
        invalidateShadow()
    }
}
