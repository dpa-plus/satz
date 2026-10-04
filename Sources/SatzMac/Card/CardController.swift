import AppKit
import SwiftUI

/// Owns the card's window: shows it near the bottom of the screen and grows
/// it upward, so the strip with the buttons stays exactly where it was.
@MainActor
final class CardController {

    private let session: Session
    private let preferences: Preferences
    private var panel: CardPanel?
    /// True from the first movement of a drag until the window has settled.
    private var dragging = false

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

    /// Hands the drag to the window server, the way a title bar moves a
    /// window: smooth at any size. Moving the window ourselves on every mouse
    /// event stuttered once the card held text.
    private func drag(_ isDragging: Bool) {
        guard let panel else { return }
        guard isDragging else {
            dragging = false
            return
        }
        guard !dragging, let event = NSApp.currentEvent else { return }
        dragging = true
        panel.performDrag(with: event)
    }

    private func make() -> CardPanel {
        let panel = CardPanel()
        panel.onMoved = { [weak self, weak panel] in
            // Only a drag by the user is remembered; satz moving the card
            // above a text field is not.
            guard let self, let panel, dragging else { return }
            dragging = false
            preferences.cardOffset = panel.offset()
        }
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

    /// Where the bottom and right edges sit, kept while the card changes size.
    private var bottom: CGFloat?
    private var right: CGFloat?
    /// Called once the user has finished dragging the card somewhere new.
    var onMoved: () -> Void = {}
    private var settling: Task<Void, Never>?
    private var settlingSize: Task<Void, Never>?

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
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
    }

    /// A drag by the window server ends without telling us; the moves stop.
    /// So the new spot is taken a moment after the last one.
    private func moved() {
        bottom = frame.minY
        right = frame.maxX
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, NSEvent.pressedMouseButtons == 0 else { return }
            self?.onMoved()
        }
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
        right = origin.x + frame.width
        setFrameOrigin(origin)
    }

    func move(to origin: NSPoint) {
        bottom = origin.y
        right = origin.x + frame.width
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
    ///
    /// One animation only, SwiftUI's, moves the card. The window first makes
    /// room for both the old and the new size, the card animates inside it,
    /// and only then does the window take the new size. Animating the window
    /// as well, on its own clock, made the text and "Paused" drift around.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard isVisible else {
            setFrame(anchored(size), display: true)
            return
        }
        let room = CGSize(width: max(frame.width, size.width), height: max(frame.height, size.height))
        if room != frame.size { setFrame(anchored(room), display: true) }
        settlingSize?.cancel()
        guard room != size else {
            invalidateShadow()
            return
        }
        settlingSize = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, !Task.isCancelled else { return }
            setFrame(anchored(size), display: true)
            invalidateShadow()
        }
    }

    /// A frame of `size` with the bottom and right edges where they belong.
    private func anchored(_ size: CGSize) -> NSRect {
        NSRect(x: (right ?? frame.maxX) - size.width, y: bottom ?? frame.minY, width: size.width, height: size.height)
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
