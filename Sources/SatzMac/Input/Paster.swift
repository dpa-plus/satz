import AppKit
import Carbon.HIToolbox
import SatzKit

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

    /// - Parameter origin: the application the user was typing in when they
    ///   started speaking. An upload takes seconds, and people switch windows
    ///   while they wait, so the transcript is sent back where it was meant to
    ///   go rather than wherever happens to be frontmost now.
    static func deliver(_ text: String, into origin: NSRunningApplication?) -> Outcome {
        guard !text.isEmpty else { return .pasted }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let blocker = whatIsBlockingPaste() {
            // Leave the transcript on the clipboard: it is the fallback.
            return .clipboardOnly(blocker)
        }

        restoreFocus(to: origin)
        sendCommandV()
        restore(previous, after: .milliseconds(400))
        return .pasted
    }

    /// nil when a synthesised Command+V will actually arrive somewhere.
    static func whatIsBlockingPaste() -> String? {
        if !AXIsProcessTrusted() {
            return de("Auf der Zwischenablage. satz braucht Bedienungshilfen-Zugriff zum Einfügen.", en: "On the clipboard. satz needs Accessibility access to paste.")
        }
        if IsSecureEventInputEnabled() {
            return de("Auf der Zwischenablage. Ein Programm blockiert gerade Tastatureingaben.", en: "On the clipboard. An app is blocking keyboard input right now.")
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

    // MARK: - Private

    private static func restoreFocus(to origin: NSRunningApplication?) {
        guard let origin, !origin.isActive, !origin.isTerminated else { return }
        origin.activate()
        // Activation is asynchronous. Without a beat the keystroke lands in the
        // old application. This is a compromise, not a guarantee.
        Thread.sleep(forTimeInterval: 0.12)
    }

    /// Hands the clipboard back. Dictating should not silently destroy whatever
    /// the user had copied, but the transcript has to sit there long enough to
    /// be pasted first.
    private static func restore(_ previous: String?, after delay: Duration) {
        guard let previous else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
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
