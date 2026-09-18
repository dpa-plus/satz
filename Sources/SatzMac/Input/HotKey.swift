import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` rather than a `CGEventTap`, for two reasons.
/// It needs no Accessibility permission to fire, so the shortcut works on first
/// launch before the user has granted anything. And it keeps working while
/// macOS Secure Input is held by some other application, which silently kills
/// event taps.
///
/// The cost is that Carbon cannot tell the left modifier key from the right one.
final class HotKey {

    struct Combination: Equatable {
        /// A `kVK_` virtual key code.
        var keyCode: UInt32
        /// Carbon modifier mask: `optionKey`, `controlKey`, `cmdKey`, `shiftKey`.
        var modifiers: UInt32

        /// Option + Space. The shortcut this app is meant to be used with.
        static let optionSpace = Combination(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        )

        var display: String {
            var parts: [String] = []
            if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
            if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
            if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
            if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
            parts.append(keyCode == UInt32(kVK_Space) ? "Space" : "Key \(keyCode)")
            return parts.joined()
        }
    }

    enum Failure: Error, LocalizedError {
        case alreadyTaken(Combination)

        var errorDescription: String? {
            switch self {
            case .alreadyTaken(let combination):
                "\(combination.display) ist schon von einem anderen Programm belegt."
            }
        }
    }

    private var reference: EventHotKeyRef?
    private let id: UInt32

    /// Registers `combination` system-wide. `action` runs on the main actor.
    init(_ combination: Combination, action: @escaping @MainActor () -> Void) throws {
        id = Dispatcher.shared.install(action: action)

        let hotKeyID = EventHotKeyID(signature: Dispatcher.signature, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            Dispatcher.shared.remove(id: id)
            // The only realistic failure is another application holding it.
            throw Failure.alreadyTaken(combination)
        }
        self.reference = reference
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Dispatcher.shared.remove(id: id)
    }
}

/// Bridges Carbon's single C callback to individual Swift closures.
///
/// Carbon hands back only an integer id, so the callback has to look the action
/// up somewhere reachable from a C function pointer. Hence one shared table.
private final class Dispatcher: @unchecked Sendable {
    static let shared = Dispatcher()
    static let signature: OSType = 0x7361747A  // 'satz'

    private let lock = NSLock()
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    func install(action: @escaping @MainActor () -> Void) -> UInt32 {
        lock.withLock {
            installHandlerIfNeeded()
            let id = nextID
            nextID += 1
            actions[id] = action
            return id
        }
    }

    func remove(id: UInt32) {
        lock.withLock { actions[id] = nil }
    }

    func fire(id: UInt32) {
        guard let action = lock.withLock({ actions[id] }) else { return }
        Task { @MainActor in action() }
    }

    /// Caller holds the lock.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr, id.signature == Dispatcher.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                Dispatcher.shared.fire(id: id.id)
                return noErr
            },
            1,
            &spec,
            nil,
            &handler
        )
    }
}
