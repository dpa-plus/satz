import AppKit
import Carbon.HIToolbox
import SatzKit

/// A system-wide key combination, through Carbon's `RegisterEventHotKey`.
///
/// Used for key combinations, where it beats an event tap on two counts: it
/// needs no permission at all, and it swallows the keystroke, so a combination
/// like ⌥ Space does not also type a non-breaking space into the focused app.
/// It cannot tell the left modifier key from the right one, and it cannot see a
/// modifier on its own; those triggers go through `TriggerMonitor`.
final class HotKey {

    struct Combination: Equatable {
        /// A `kVK_` virtual key code.
        var keyCode: UInt32
        /// Carbon modifier mask: `optionKey`, `controlKey`, `cmdKey`, `shiftKey`.
        var modifiers: UInt32

        /// Escape, held only while recording so it is not stolen the rest of
        /// the time.
        static let escape = Combination(keyCode: UInt32(kVK_Escape), modifiers: 0)
    }

    enum Failure: Error, LocalizedError {
        case alreadyTaken
        case noHandler

        var errorDescription: String? {
            switch self {
            case .alreadyTaken: de("Diese Tasten sind schon von einem anderen Programm belegt.", en: "Another app already uses these keys.")
            case .noHandler: de("Tastenkürzel konnten nicht eingerichtet werden.", en: "The shortcut could not be set up.")
            }
        }
    }

    /// Whether macOS itself uses the combination (Spotlight, input sources,
    /// screenshots…): those win, and satz never hears the keys. Another app's
    /// hotkey cannot be seen: Carbon registers a second one without a word,
    /// and even an exclusive registration only blocks apps that come later.
    static func isUsedByMacOS(_ combination: Combination) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let array = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return array.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return UInt32(code) == combination.keyCode && UInt32(modifiers) & mask == combination.modifiers & mask
        }
    }

    /// Combinations launchers and AI apps usually claim (Raycast, Alfred,
    /// ChatGPT, Spotlight): worth a warning, since a clash cannot be detected.
    static func isOftenClaimed(_ combination: Combination) -> Bool {
        guard combination.keyCode == UInt32(kVK_Space) else { return false }
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return [UInt32(optionKey), UInt32(cmdKey), UInt32(controlKey), UInt32(cmdKey | optionKey), UInt32(controlKey | optionKey)]
            .contains(combination.modifiers & mask)
    }

    private var reference: EventHotKeyRef?
    private let id: UInt32

    /// Registers `combination` system-wide. Both closures run on the main actor.
    init(
        _ combination: Combination,
        onPress: @escaping @MainActor () -> Void,
        onRelease: (@MainActor () -> Void)? = nil
    ) throws {
        guard let id = Dispatcher.shared.install(onPress: onPress, onRelease: onRelease) else {
            throw Failure.noHandler
        }
        self.id = id

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            EventHotKeyID(signature: Dispatcher.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            Dispatcher.shared.remove(id: id)
            // The only realistic failure is another application holding it.
            throw Failure.alreadyTaken
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

    private struct Actions {
        let onPress: @MainActor () -> Void
        let onRelease: (@MainActor () -> Void)?
    }

    private let lock = NSLock()
    private var actions: [UInt32: Actions] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    /// nil if the Carbon handler could not be installed, in which case no
    /// hotkey would ever fire and registering one would be a lie.
    func install(
        onPress: @escaping @MainActor () -> Void,
        onRelease: (@MainActor () -> Void)?
    ) -> UInt32? {
        lock.withLock {
            guard installHandlerIfNeeded() else { return nil }
            let id = nextID
            nextID += 1
            actions[id] = Actions(onPress: onPress, onRelease: onRelease)
            return id
        }
    }

    func remove(id: UInt32) {
        lock.withLock { actions[id] = nil }
    }

    func fire(id: UInt32, pressed: Bool) {
        guard let entry = lock.withLock({ actions[id] }) else { return }
        Task { @MainActor in
            if pressed { entry.onPress() } else { entry.onRelease?() }
        }
    }

    /// Caller holds the lock.
    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
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
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                Dispatcher.shared.fire(id: id.id, pressed: pressed)
                return noErr
            },
            specs.count,
            &specs,
            nil,
            &handler
        )
        return status == noErr
    }
}
