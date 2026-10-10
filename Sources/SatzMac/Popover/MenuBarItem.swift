import AppKit
import SwiftUI

/// The menu bar icon and the panel it opens.
///
/// A panel rather than an NSPopover: it can be drawn exactly as designed, with
/// no system arrow and no material behind the brand colours, and it closes on
/// any click outside it the way a menu does.
@MainActor
final class MenuBarItem {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dot = AttentionDot()
    private var panel: PopoverPanel?
    private var outsideClicks: Any?
    /// Clicks in satz's own windows, which the global monitor does not see:
    /// the menu stayed open over the settings or the card.
    private var ownClicks: Any?
    private var escape: Any?
    private let content: () -> AnyView

    init(content: @escaping () -> AnyView) {
        self.content = content

        guard let button = item.button else { return }
        button.image = Self.mark()
        button.target = self
        button.action = #selector(toggle)
        button.setAccessibilityLabel("satz")

        // A dot on the icon when something needs attention, so a problem is
        // visible without opening anything.
        dot.frame = NSRect(x: button.bounds.width - 7, y: button.bounds.height - 8, width: 6, height: 6)
        dot.autoresizingMask = [.minXMargin, .minYMargin]
        dot.isHidden = true
        button.addSubview(dot)
    }

    var needsAttention = false {
        didSet {
            dot.isHidden = !needsAttention
            // Set again whenever the colour family may have changed.
            dot.needsDisplay = true
        }
    }

    var isOpen: Bool { panel?.isVisible == true }

    @objc func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    func open() {
        // Open already (the test command `menu` does not ask): a second set
        // of monitors would be lost, and the first one's Escape handler would
        // swallow every Escape in satz for the rest of the session.
        guard !isOpen else { return }
        removeMonitors()
        let panel = panel ?? PopoverPanel()
        self.panel = panel

        let hosting = NSHostingView(rootView: content().themed())
        panel.contentView = hosting
        place(panel, size: hosting.fittingSize)
        panel.orderFrontRegardless()
        panel.makeKey()

        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        ownClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Not the menu itself, and not the icon, whose own click toggles it.
            if let self, event.window !== panel, event.window !== item.button?.window { close() }
            return event
        }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            self?.close()
            return nil
        }
    }

    func close() {
        panel?.orderOut(nil)
        removeMonitors()
    }

    private func removeMonitors() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let ownClicks { NSEvent.removeMonitor(ownClicks) }
        if let escape { NSEvent.removeMonitor(escape) }
        outsideClicks = nil
        ownClicks = nil
        escape = nil
    }

    /// Top-right corner under the icon, kept on screen.
    private func place(_ panel: NSPanel, size: NSSize) {
        guard let button = item.button, let window = button.window else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        let x = min(icon.maxX + 8, screen.maxX - 8) - size.width
        let y = icon.minY - 6 - size.height
        panel.setFrame(NSRect(x: max(screen.minX + 8, x), y: y, width: size.width, height: size.height), display: true)
    }

    /// The brand mark, as a template image so macOS tints it for the menu bar.
    private static func mark() -> NSImage {
        let shape: [CGFloat] = [0.30, 0.55, 0.80, 1.00, 0.80, 0.55, 0.30]
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { rect in
            let bar: CGFloat = 1.9
            let gap = (rect.width - bar * CGFloat(shape.count)) / CGFloat(shape.count - 1)
            NSColor.black.setFill()
            for (index, scale) in shape.enumerated() {
                let height = rect.height * (0.25 + 0.75 * scale)
                let x = CGFloat(index) * (bar + gap)
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: (rect.height - height) / 2, width: bar, height: height),
                    xRadius: bar / 2, yRadius: bar / 2
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The dot on the menu bar icon. Its colour is the colour family's accent in
/// the appearance of the menu bar, not of the windows: the light accent on a
/// dark bar was 1.9:1 for Forest. The status button reports the bar's own
/// appearance, which follows the wallpaper as well as the Mac's setting.
@MainActor
final class AttentionDot: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor(dark ? Theme.dark.accent : Theme.light.accent).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}

/// Borderless, see-through, and able to take keyboard focus without making
/// satz the active application: Escape and the microphone menu work, and the
/// app you were typing in stays in front.
final class PopoverPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
}
