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
    private let dot = NSView()
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

        // An orange dot on the icon when something needs attention, so a
        // problem is visible without opening anything.
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(Theme.light.accent).cgColor
        dot.layer?.cornerRadius = 3
        dot.frame = NSRect(x: button.bounds.width - 7, y: button.bounds.height - 8, width: 6, height: 6)
        dot.autoresizingMask = [.minXMargin, .minYMargin]
        dot.isHidden = true
        button.addSubview(dot)
    }

    var needsAttention = false {
        didSet {
            dot.isHidden = !needsAttention
            // The dot takes the current colour family's accent.
            dot.layer?.backgroundColor = NSColor(Theme.light.accent).cgColor
        }
    }

    var isOpen: Bool { panel?.isVisible == true }

    @objc func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    func open() {
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
