import AppKit
import Carbon.HIToolbox
import SatzKit

/// Puts the transcript where the user was typing.
///
/// There is no supported way to insert text into another application's text
/// field, so this does what every dictation tool does: put the text on the
/// pasteboard and synthesise Command+V. Without Accessibility the synthesised
/// keys go nowhere; then the text stays on the clipboard, nothing is lost,
/// and the user is told to press Command+V themselves.
///
/// Secure Input is not a reason to stop. It keeps apps from reading keys, not
/// from sending them, and an app can leave it on by mistake: on 07.10. the
/// Claude app held it for hours and every dictation ended on the clipboard.
@MainActor
enum Paster {

    enum Outcome: Equatable {
        case pasted
        /// On the clipboard but not inserted, with a reason to show the user.
        case clipboardOnly(String)
    }

    /// - Parameters:
    ///   - origin: the application the user was typing in when they started
    ///     speaking. An upload takes seconds, and people switch windows while
    ///     they wait, so the transcript is sent back where it was meant to go
    ///     rather than wherever happens to be frontmost now.
    ///   - keepsOnClipboard: the transcript stays on the clipboard afterwards,
    ///     instead of what was copied before.
    static func deliver(_ text: String, into origin: NSRunningApplication?, keepsOnClipboard: Bool = false) -> Outcome {
        guard !text.isEmpty else { return .pasted }

        let pasteboard = NSPasteboard.general
        let previous = copy(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount

        if let blocker = whatIsBlockingPaste() {
            // Leave the transcript on the clipboard: it is the fallback.
            return .clipboardOnly(blocker)
        }
        // Started while satz itself was in front (its settings, say): ⌘V
        // would go to satz, and with no field there the text went nowhere.
        guard origin != nil else {
            return .clipboardOnly(de("Auf der Zwischenablage.", en: "On the clipboard."))
        }

        // Whether ⌘V landed cannot be seen. While some app holds Secure Input
        // the text stays on the clipboard too, so ⌘V by hand always works.
        let secure = IsSecureEventInputEnabled()
        if secure { Log.note("paste: Secure Input is on (held by \(secureInputHolder())), sent ⌘V anyway and kept the text on the clipboard") }
        restoreFocus(to: origin)
        sendCommandV()
        if !keepsOnClipboard, !secure {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                putBack(previous, on: pasteboard, ifStill: ours)
            }
        }
        return .pasted
    }

    /// nil when a synthesised Command+V will actually arrive somewhere.
    static func whatIsBlockingPaste() -> String? {
        if !AXIsProcessTrusted() {
            return de("Auf der Zwischenablage. satz braucht Bedienungshilfen-Zugriff zum Einfügen.", en: "On the clipboard. satz needs Accessibility access to paste.")
        }
        return nil
    }

    /// The app that switched Secure Input on, for the log.
    static func secureInputHolder() -> String {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int32 else { return "?" }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
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

    /// Everything on the clipboard, in every form it was offered in. Only the
    /// plain text was kept before, so a copied picture or file was gone after
    /// one dictation.
    static func copy(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Hands the clipboard back once the transcript has been pasted. Dictating
    /// should not destroy whatever the user had copied, but only while the
    /// transcript is still what is there: something copied in the meantime
    /// stays.
    static func putBack(_ previous: [NSPasteboardItem], on pasteboard: NSPasteboard, ifStill ours: Int) {
        guard !previous.isEmpty, pasteboard.changeCount == ours else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(previous)
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
