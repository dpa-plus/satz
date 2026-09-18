import AppKit
import Carbon.HIToolbox

/// Puts the transcript where the user was typing.
///
/// There is no supported way to insert text into another application's text
/// field, so this does what every dictation tool does: put the text on the
/// pasteboard and synthesise Command+V. Two things can stop that, and both are
/// handled by falling back rather than failing:
///
/// - Accessibility has not been granted, so synthesised keys go nowhere.
/// - Another application holds macOS Secure Input, which swallows them.
///
/// In both cases the text is already on the clipboard, so nothing is lost and
/// the user is told to press Command+V themselves.
@MainActor
enum Paster {

    enum Outcome: Equatable {
        case pasted
        /// On the clipboard but not inserted, with a reason to show the user.
        case clipboardOnly(String)
    }

    static func deliver(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .pasted }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let blocker = whatIsBlockingPaste() {
            return .clipboardOnly(blocker)
        }
        sendCommandV()
        return .pasted
    }

    /// nil when a synthesised Command+V will actually arrive somewhere.
    static func whatIsBlockingPaste() -> String? {
        if !AXIsProcessTrusted() {
            return "Auf der Zwischenablage. satz braucht Bedienungshilfen-Zugriff zum Einfügen."
        }
        if IsSecureEventInputEnabled() {
            return "Auf der Zwischenablage. Ein Programm blockiert gerade Tastatureingaben."
        }
        return nil
    }

    /// Opens System Settings at the Accessibility pane, and prompts the first time.
    static func requestAccessibility() {
        // The literal rather than kAXTrustedCheckOptionPrompt: that constant is
        // an unannotated global var, which Swift 6 rejects as shared mutable
        // state. Its value is this string and has been since the API shipped.
        let options = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private static func sendCommandV() {
        // .combinedSessionState so the event carries the real modifier state of
        // the session rather than a private one, which some applications check.
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)

        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
