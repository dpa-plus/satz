import AppKit
import SwiftUI

/// Owns the card's window: shows it near the bottom of the screen and grows
/// it upward, so the strip with the buttons stays exactly where it was.
@MainActor
final class CardController {

    private let session: Session
    private let preferences: Preferences
    private var panel: CardPanel?
    /// Where the window and the mouse were when a drag began.
    private var dragStart: (window: NSPoint, mouse: NSPoint)?

    init(session: Session, preferences: Preferences) {
        self.session = session
        self.preferences = preferences
    }

    func show() {
        let panel = panel ?? make()
        self.panel = panel
        if !panel.isVisible {
            panel.place(offset: preferences.cardOffset, avoiding: FocusedField.frame())
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The live card as a PNG, drawn by AppKit itself: real text view, real
    /// layout. For test mode, where no screenshot tool can see the panel.
    func picture() -> Data? {
        guard let view = panel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Follows the mouse in screen coordinates rather than the gesture's own,
    /// which move with the window being dragged and would make it jitter.
    private func drag(_ dragging: Bool) {
        guard let panel else { return }
        guard dragging else {
            dragStart = nil
            preferences.cardOffset = panel.offset()
            return
        }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (panel.frame.origin, mouse) }
        guard let start = dragStart else { return }
        panel.move(to: NSPoint(x: start.window.x + mouse.x - start.mouse.x, y: start.window.y + mouse.y - start.mouse.y))
    }

    private func make() -> CardPanel {
        let panel = CardPanel()
        let view = CardView(
            session: session, preferences: preferences,
            onSize: { [weak panel] size in panel?.resize(to: size) },
            onDrag: { [weak self] dragging in self?.drag(dragging) }
        )
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
            contentRect: NSRect(x: 0, y: 0, width: CardView.width, height: 38),
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

    /// Near the bottom centre of the screen holding the mouse, which is where
    /// the user is already looking, or where they last dragged it to.
    ///
    /// Never on top of the field being dictated into: a chat box at the bottom
    /// of a window is exactly where the card would otherwise sit. Then it
    /// goes just above the field, where growing upward cannot cover it either.
    func place(offset: CGPoint?, avoiding field: NSRect?) {
        guard let visible = Self.screen()?.visibleFrame else { return }
        let base = NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 96)
        var origin = NSPoint(x: base.x + (offset?.x ?? 0), y: base.y + (offset?.y ?? 0))
        let card = NSRect(origin: origin, size: frame.size)
        if let field, card.insetBy(dx: 0, dy: -8).intersects(field) {
            origin.y = field.maxY + 12
        }
        // Kept on screen, also when the remembered spot was on a larger display.
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        bottom = origin.y
        setFrameOrigin(origin)
    }

    func move(to origin: NSPoint) {
        bottom = origin.y
        setFrameOrigin(origin)
    }

    /// The card's spot as an offset from the default one, for remembering.
    func offset() -> CGPoint {
        guard let visible = (screen ?? Self.screen())?.visibleFrame else { return .zero }
        return CGPoint(x: frame.minX - (visible.midX - frame.width / 2), y: frame.minY - (visible.minY + 96))
    }

    private static func screen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    /// Taller or shorter with the text, bottom edge fixed; wider or narrower
    /// from the right edge, so the eye and x stay under the mouse that just
    /// clicked them.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let origin = NSPoint(x: frame.maxX - size.width, y: bottom ?? frame.minY)
        setFrame(NSRect(origin: origin, size: size), display: true)
        invalidateShadow()
    }
}

/// Where the text field the user is typing in sits on screen, read through
/// Accessibility (which satz has anyway, to paste).
enum FocusedField {

    /// In AppKit screen coordinates. nil when it cannot be known, or when
    /// what has focus is too big to be a text field (some apps report their
    /// whole web view), which would push the card off the screen.
    static func frame() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        // An app that hangs must not hang satz.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(field, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.height > 0, size.height < 300 else { return nil }

        // Accessibility counts from the top of the main screen, AppKit from the bottom.
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: position.x, y: mainHeight - position.y - size.height, width: size.width, height: size.height)
    }
}
