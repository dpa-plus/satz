import AppKit
import SwiftUI

/// Owns the card's window: shows it near the bottom of the screen, where the
/// card grows upward so the row with the buttons stays exactly where it was.
@MainActor
final class CardController {

    private let session: Session
    private let preferences: Preferences
    private var panel: CardPanel?
    /// Where the mouse and the window were when the current drag began.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(session: Session, preferences: Preferences) {
        self.session = session
        self.preferences = preferences
    }

    func show() {
        var panel = panel ?? make()
        self.panel = panel
        if !panel.isVisible {
            panel.place(offset: preferences.cardOffset, avoiding: FocusedField.frame())
            panel.orderFrontRegardless()
            // After a night's sleep the window was left on one desktop only,
            // so every card after that came up on a desktop the user was not
            // looking at. A new window joins every desktop again.
            if !panel.isOnActiveSpace {
                Log.note("card was on another desktop only; replaced")
                panel.orderOut(nil)
                panel = make()
                self.panel = panel
                panel.place(offset: preferences.cardOffset, avoiding: FocusedField.frame())
                panel.orderFrontRegardless()
            }
            Log.note("card shown at \(NSStringFromRect(panel.frame)) on a screen of \(NSStringFromRect(panel.screen?.frame ?? .zero)), visible \(panel.isOnActiveSpace)")
        }
    }

    /// The window server's number for the card's window, for test mode.
    var windowNumber: Int? { panel?.windowNumber }

    func hide() {
        panel?.orderOut(nil)
    }

    /// For test mode's state file.
    var frameDescription: String {
        panel.map { NSStringFromRect($0.frame) } ?? "none"
    }

    /// The live card as a PNG, drawn by AppKit itself: real text view, real
    /// layout. For test mode, where no screenshot tool can see the panel.
    func picture() -> Data? {
        guard let view = panel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Moves the window with the mouse, measured on the screen rather than in
    /// the card (which moves with it), and never past the edge of the screen:
    /// the card stops at the wall, even while the mouse goes on. The window
    /// server's own drag had no wall and let the card slide half off screen.
    private func drag(_ isDragging: Bool) {
        guard let panel else { return }
        guard isDragging else {
            dragStart = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, panel.frame.origin)
        dragStart = start
        let wanted = NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        panel.setFrameOrigin(panel.keptOnScreen(wanted, mouse: mouse))
    }

    private func make() -> CardPanel {
        let panel = CardPanel()
        panel.onMoved = { [weak self, weak panel] in
            // Every move but satz's own placing is the user's, and is kept.
            guard let self, let panel else { return }
            preferences.cardOffset = panel.offset()
        }
        let view = CardView(session: session, preferences: preferences) { [weak self] dragging in
            self?.drag(dragging)
        }
        let hosting = NSHostingView(rootView: view.themed())
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

/// Floats above everything, follows the user across desktops, and takes the
/// keyboard only when the user clicks into the text. Pressing a button on
/// the card leaves the app they were typing in focused.
///
/// The window never changes size. It is as big as the card can get, plus a
/// margin for the shadow, and see-through around the card, which sits in its
/// bottom right corner and animates inside it. Resizing the window as well,
/// on its own clock, made the card flicker and jump when it grew. Clicks on
/// the see-through part go to whatever is underneath.
final class CardPanel: NSPanel {

    /// Room around the card for its shadow.
    static let margin: CGFloat = 18
    static let size = CGSize(
        width: CardView.width + 2 * margin,
        height: CardView.maxTextHeight + 1 + CardView.rowHeight + 2 * margin
    )

    /// Called once the user has finished dragging the card somewhere new.
    var onMoved: () -> Void = {}
    private var settling: Task<Void, Never>?
    /// True while satz itself puts the window somewhere, which is not a drag.
    private var placing = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        // The card draws its own shadow, inside the margin.
        hasShadow = false
        // The card is always the dark surface, so its glass is always the
        // dark kind too, instead of following the system into light glass.
        appearance = NSAppearance(named: .darkAqua)
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
        guard !placing else { return }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, NSEvent.pressedMouseButtons == 0 else { return }
            self?.onMoved()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Where the window goes by default: the pill centred near the bottom of
    /// the screen. The card sits in the window's right corner and grows to
    /// the left from there, so the buttons stay where they are.
    private static func base(in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.midX + CardView.pillWidth / 2 + margin - size.width, y: visible.minY + 96 - margin)
    }

    /// Near the bottom centre of the screen holding the mouse, which is where
    /// the user is already looking, or where they last dragged it to.
    ///
    /// Never on top of the field being dictated into: a chat box at the bottom
    /// of a window is exactly where the card would otherwise sit. Then it
    /// goes just above the field, where growing upward cannot cover it either.
    /// Only from the default spot: a place the user dragged it to is theirs,
    /// and moving it away from there looked like it was never remembered.
    func place(offset: CGPoint?, avoiding field: NSRect?) {
        guard let visible = Self.screen()?.visibleFrame else { return }
        let base = Self.base(in: visible)
        var origin = NSPoint(x: base.x + (offset?.x ?? 0), y: base.y + (offset?.y ?? 0))
        // The card's bottom row, where it first appears.
        let row = NSRect(x: origin.x + Self.margin, y: origin.y + Self.margin, width: CardView.width, height: CardView.rowHeight)
        if offset == nil, let field, row.insetBy(dx: 0, dy: -8).intersects(field) {
            origin.y = field.maxY + 12 - Self.margin
        }
        // Kept on screen, also when the remembered spot was on a larger display.
        origin = Self.clamped(origin, in: visible, size: frame.size)
        placing = true
        setFrameOrigin(origin)
        placing = false
    }

    /// `origin` moved just enough that the whole card, also at full size,
    /// stays on the screen under the mouse.
    func keptOnScreen(_ origin: NSPoint, mouse: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? self.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        return Self.clamped(origin, in: visible, size: frame.size)
    }

    /// The margin around the card is see-through, so it may leave the screen.
    private static func clamped(_ origin: NSPoint, in visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visible.minX - margin), visible.maxX - size.width + margin),
            y: min(max(origin.y, visible.minY - margin), visible.maxY - size.height + margin)
        )
    }

    /// The card's spot as an offset from the default one, for remembering.
    func offset() -> CGPoint {
        guard let visible = (screen ?? Self.screen())?.visibleFrame else { return .zero }
        let base = Self.base(in: visible)
        return CGPoint(x: frame.minX - base.x, y: frame.minY - base.y)
    }

    private static func screen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}

/// Where the text field the user is typing in sits on screen, read through
/// Accessibility (which satz has anyway, to paste).
enum FocusedField {

    /// Whether the app has a place to type in focused: a text field, a text
    /// area, or editable web content. Asked by the menu's Insert button,
    /// which has nowhere to put text otherwise. The app is asked by its
    /// process, because the open menu holds the keyboard itself.
    static func isEditable(in app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let field = element as! AXUIElement
        // The timeout is per element: the app's alone left this one unbounded.
        AXUIElementSetMessagingTimeout(field, 0.25)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
        var settable: DarwinBoolean = false
        let canSet = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        // A read-only text view is an AXTextArea too, and refuses the paste.
        if let role = role as? String, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role), canSet { return true }
        // A slider's value is settable too; only text counts.
        var value: CFTypeRef?
        if canSet, AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success, value is String { return true }
        // Browsers mark what lies inside an editable web area.
        var ancestor: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, "AXEditableAncestor" as CFString, &ancestor) == .success && ancestor != nil
    }

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
        AXUIElementSetMessagingTimeout(field, 0.25)

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
