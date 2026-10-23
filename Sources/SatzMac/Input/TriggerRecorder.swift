import AppKit
import Carbon.HIToolbox

/// Captures the next key combination or mouse button the user presses, to
/// make it the trigger.
@MainActor
final class TriggerRecorder {

    enum Kind {
        case keys
        case mouse
    }

    private var monitors: [Any] = []
    private var completion: ((Trigger?) -> Void)?
    private var pendingModifiers: UInt32 = 0

    /// Calls `completion` once with the captured trigger, or nil if the user
    /// pressed Escape.
    func record(_ kind: Kind, completion: @escaping (Trigger?) -> Void) {
        stop()
        self.completion = completion

        let events: NSEvent.EventTypeMask = kind == .keys ? [.keyDown, .flagsChanged] : .keyDown
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, kind: kind)
        } as Any)

        if kind == .mouse {
            let capture: (NSEvent) -> Void = { [weak self] event in
                // 0 and 1 are the left and right buttons: never the trigger.
                guard event.buttonNumber > 1 else { return }
                Task { @MainActor in self?.finish(.mouseButton(event.buttonNumber)) }
            }
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
                capture(event)
                return nil
            } as Any)
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown, handler: capture) {
                monitors.append(global)
            }
        }
    }

    func handle(_ event: NSEvent, kind: Kind) -> NSEvent? {
        if kind == .keys, event.type == .flagsChanged {
            let mask = event.modifierFlags.carbonModifiers
            // Wait for a release: Option+Command may still become
            // Option+Command+K, and must then keep its regular key.
            if pendingModifiers != 0, mask & pendingModifiers != pendingModifiers {
                finish(.modifiers(pendingModifiers))
            } else if mask.nonzeroBitCount >= 2 {
                pendingModifiers = mask
            }
            return event
        }
        guard event.type == .keyDown else { return event }
        pendingModifiers = 0
        if event.keyCode == UInt16(kVK_Escape) {
            finish(nil)
            return nil
        }
        guard kind == .keys, let trigger = Self.keys(from: event) else { return nil }
        finish(trigger)
        return nil
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        completion = nil
        pendingModifiers = 0
    }

    private func finish(_ trigger: Trigger?) {
        let done = completion
        stop()
        done?(trigger)
    }

    /// A key needs at least one modifier, or has to be a function key: a bare
    /// letter as a global trigger would make that letter untypable.
    private static func keys(from event: NSEvent) -> Trigger? {
        let mask = event.modifierFlags.carbonModifiers

        let functionKeys = Trigger.functionKeys.contains(Int(event.keyCode))
        let onlyShift = mask == UInt32(shiftKey)
        guard (mask != 0 && !onlyShift) || functionKeys else { return nil }
        return .keys(keyCode: UInt32(event.keyCode), modifiers: mask)
    }
}
