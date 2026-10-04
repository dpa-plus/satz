import Carbon.HIToolbox
import Foundation
import SatzKit

/// What starts and stops a dictation.
///
/// The default is the right ⌘ key tapped twice: one of macOS's own dictation
/// shortcut choices, present on every Mac keyboard, and it types nothing. The
/// earlier default, ⌥ Space, types a non-breaking space and is already taken
/// by Raycast, Alfred and the ChatGPT app on many Macs.
enum Trigger: Codable, Equatable, Sendable {
    case doubleRightCommand
    /// A key with modifiers. Carbon key code and Carbon modifier mask.
    case keys(keyCode: UInt32, modifiers: UInt32)
    /// A mouse button other than the left and right ones, by CGEvent number:
    /// 2 is the wheel, 3 and 4 are the usual side buttons.
    case mouseButton(Int)

    static let standard: Trigger = .doubleRightCommand

    /// Key combinations go through Carbon, which needs no permission. The other
    /// two watch raw keyboard and mouse events, which needs Accessibility.
    var needsEventTap: Bool {
        if case .keys = self { false } else { true }
    }

    /// The keycaps to draw, then the words after them.
    var display: (keys: [(glyph: String, name: String?)], words: String?) {
        switch self {
        case .doubleRightCommand:
            ([("⌘", "cmd")], de("rechts, zweimal", en: "right, twice"))
        case .keys(let keyCode, let modifiers):
            (Self.modifierKeys(modifiers) + [(Self.keyName(keyCode), nil)], nil)
        case .mouseButton(let number):
            ([], Self.mouseButtonName(number))
        }
    }

    // MARK: - Names

    private static func modifierKeys(_ mask: UInt32) -> [(glyph: String, name: String?)] {
        var keys: [(String, String?)] = []
        if mask & UInt32(controlKey) != 0 { keys.append(("⌃", "ctrl")) }
        // German Apple keyboards print "alt" on this key, US ones "option".
        if mask & UInt32(optionKey) != 0 {
            keys.append(("⌥", Locale.current.language.languageCode == .german ? "alt" : "option"))
        }
        if mask & UInt32(shiftKey) != 0 { keys.append(("⇧", "shift")) }
        if mask & UInt32(cmdKey) != 0 { keys.append(("⌘", "cmd")) }
        return keys
    }

    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return de("Leertaste", en: "Space")
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return de("Löschen", en: "Delete")
        default:
            if let index = functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
            return typedCharacter(keyCode)?.uppercased() ?? de("Taste \(keyCode)", en: "Key \(keyCode)")
        }
    }

    /// F1 to F20, in order. Their key codes are not contiguous (F1 is 0x7A,
    /// F2 is 0x78, F3 is 0x63), so a range would be wrong.
    static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// The character the key types on the current keyboard layout, so a
    /// German user sees "Z" where a US user sees "Y" for the same key.
    private static func typedCharacter(_ keyCode: UInt32) -> String? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    private static func mouseButtonName(_ number: Int) -> String {
        switch number {
        case 2: de("Mittlere Maustaste", en: "Middle mouse button")
        case 3: de("Maustaste zurück", en: "Mouse back button")
        case 4: de("Maustaste vor", en: "Mouse forward button")
        default: de("Maustaste \(number + 1)", en: "Mouse button \(number + 1)")
        }
    }
}

/// Whether a trigger starts and stops on separate presses, or records only
/// while it is held down.
enum TriggerMode: String, CaseIterable, Sendable {
    case tap
    case hold
}
