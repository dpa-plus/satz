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

    /// Calls `completion` once with the captured trigger, or nil if the user
    /// pressed Escape.
    func record(_ kind: Kind, completion: @escaping (Trigger?) -> Void) {
        stop()
        self.completion = completion

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.finish(nil)
                return nil
            }
            guard kind == .keys, let trigger = Self.keys(from: event) else { return nil }
            self.finish(trigger)
            return nil
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

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        completion = nil
    }

    private func finish(_ trigger: Trigger?) {
        let done = completion
        stop()
        done?(trigger)
    }

    /// A key needs at least one modifier, or has to be a function key: a bare
    /// letter as a global trigger would make that letter untypable.
    private static func keys(from event: NSEvent) -> Trigger? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }

        let functionKeys = Trigger.functionKeys.contains(Int(event.keyCode))
        let onlyShift = mask == UInt32(shiftKey)
        guard (mask != 0 && !onlyShift) || functionKeys else { return nil }
        return .keys(keyCode: UInt32(event.keyCode), modifiers: mask)
    }
}
