import AppKit
import Carbon.HIToolbox

/// Watches raw keyboard and mouse events for the triggers Carbon cannot see:
/// the right ⌘ key tapped twice, and a mouse button.
///
/// Built on a CGEventTap, which needs the Accessibility permission. The same
/// permission satz already asks for to paste, so no second prompt. Without it
/// the tap cannot be created and `init` returns nil.
final class TriggerMonitor {

    private let trigger: Trigger
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// What the system says is held down right now, apart from the events the
    /// tap has seen: the only way to find out about a release that happened
    /// while the tap was off. Tests replace it.
    struct Held {
        var rightCommand: () -> Bool = {
            // NX_DEVICERCMDKEYMASK, as in `modifierChanged`.
            CGEventSource.flagsState(.combinedSessionState).rawValue & 0x10 != 0
        }
        var mouseButton: (Int) -> Bool = { number in
            guard let button = CGMouseButton(rawValue: UInt32(number)) else { return false }
            return CGEventSource.buttonState(.combinedSessionState, button: button)
        }
    }
    private let held: Held

    // Double-tap state. Only touched on the main run loop, where the tap runs.
    private var rightCommandDownAt: Date?
    private var lastTapUpAt: Date?
    private var interrupted = false
    private var holding = false
    /// The trigger's mouse button went down and its release was not seen yet.
    private var mouseHolding = false

    /// A tap is quick. A second tap has to follow the first within this.
    private static let tapLength: TimeInterval = 0.35
    private static let tapGap: TimeInterval = 0.4

    /// Without a tap: events reach `handle` only when the caller passes them.
    init(
        trigger: Trigger,
        held: Held,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) {
        self.trigger = trigger
        self.held = held
        self.onPress = onPress
        self.onRelease = onRelease
    }

    convenience init?(
        trigger: Trigger,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) {
        guard trigger.needsEventTap else { return nil }
        self.init(trigger: trigger, held: Held(), onPress: onPress, onRelease: onRelease)

        // Clicks too: two quick ⌘-clicks with the right command key read as two taps.
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active rather than listen-only, so a mouse button used as the
            // trigger does not also go "back" in the browser.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<TriggerMonitor>.fromOpaque(info).takeUnretainedValue()
                return monitor.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    /// Runs on the main thread: the tap's source is on the main run loop.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it is ever slow. Switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release while it was off was never seen: held to talk, the
            // dictation ran on until some later right-⌘ shortcut ended it.
            lastTapUpAt = nil
            interrupted = true
            if holding, !held.rightCommand() {
                holding = false
                fire(onRelease)
            }
            // The same for a mouse button held to talk: its release is not
            // coming either, and a click on it would only start a new press.
            if mouseHolding, case .mouseButton(let number) = trigger, !held.mouseButton(number) {
                mouseHolding = false
                fire(onRelease)
            }
        case .flagsChanged:
            modifierChanged(event)
        case .keyDown, .leftMouseDown, .rightMouseDown:
            // ⌘C or a ⌘-click with the right command key is not a tap.
            interrupted = true
            lastTapUpAt = nil
        case .otherMouseDown, .otherMouseUp:
            if type == .otherMouseDown { interrupted = true; lastTapUpAt = nil }
            if case .mouseButton(let number) = trigger,
               event.getIntegerValueField(.mouseEventButtonNumber) == Int64(number) {
                mouseHolding = type == .otherMouseDown
                fire(type == .otherMouseDown ? onPress : onRelease)
                return nil  // swallowed: the button belongs to satz now
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func modifierChanged(_ event: CGEvent) {
        guard case .doubleRightCommand = trigger else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_RightCommand) else {
            // Any other modifier between the taps breaks the sequence.
            interrupted = true
            lastTapUpAt = nil
            return
        }

        // NX_DEVICERCMDKEYMASK: the right command key specifically, so holding
        // the left one does not make the right one look pressed.
        let rightDown = event.flags.rawValue & 0x10 != 0
        let now = Date()

        if rightDown {
            if let last = lastTapUpAt, now.timeIntervalSince(last) < Self.tapGap, !interrupted {
                lastTapUpAt = nil
                holding = true
                fire(onPress)
            } else {
                rightCommandDownAt = now
                interrupted = false
            }
        } else {
            if holding {
                holding = false
                fire(onRelease)
            } else if let down = rightCommandDownAt, now.timeIntervalSince(down) < Self.tapLength, !interrupted {
                lastTapUpAt = now
            }
            rightCommandDownAt = nil
        }
    }

    private func fire(_ action: @escaping @MainActor () -> Void) {
        MainActor.assumeIsolated { action() }
    }
}
