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
    ///   - window, field: where the keyboard was in `origin` when the user
    ///     started; brought back first if the user went to another window of
    ///     the same app meanwhile.
    static func deliver(_ text: String, into origin: NSRunningApplication?, window: AXUIElement? = nil, field: AXUIElement? = nil,
                        keepsOnClipboard: Bool = false) -> Outcome {
        guard !text.isEmpty else { return .pasted }

        let pasteboard = NSPasteboard.general
        // A paste right after another (Insert while a dictation finishes)
        // keeps the clipboard the user had before both: saved now, it was the
        // first transcript, and that came back instead.
        let previous = waiting?.previous ?? copy(of: pasteboard)
        waiting?.restore.cancel()
        waiting = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount

        if let blocker = whatIsBlockingPaste() {
            // Leave the transcript on the clipboard: it is the fallback.
            return .clipboardOnly(blocker)
        }
        // Started while satz itself was in front (its settings, say): ⌘V
        // would go to satz, and with no field there the text went nowhere.
        guard let origin else {
            return .clipboardOnly(de("Auf der Zwischenablage.", en: "On the clipboard."))
        }
        guard !origin.isTerminated else {
            return .clipboardOnly(de("Auf der Zwischenablage, die App wurde beendet.", en: "On the clipboard, the app was closed."))
        }

        if IsSecureEventInputEnabled() { Log.note("paste: Secure Input is on (held by \(secureInputHolder())), sending ⌘V anyway") }
        // satz's own menu had the keyboard (the Insert button, or the menu
        // left open at the end of a dictation): ⌘V went to the menu.
        closeMenus()
        waitUntil(timeout: 0.2) { NSApp.keyWindow == nil }
        guard bringForward(origin) else {
            return .clipboardOnly(de("Auf der Zwischenablage, die App ließ sich nicht aktivieren.", en: "On the clipboard, the app could not be brought forward."))
        }
        guard bringBack(window: window, field: field, in: origin) else {
            return .clipboardOnly(de("Auf der Zwischenablage, das Fenster ist nicht mehr da.", en: "On the clipboard, the window is gone."))
        }
        sendCommandV()
        if !keepsOnClipboard {
            // A second, not 400 ms: a busy app (Word, a remote desktop) took ⌘V
            // after the old clipboard was back and pasted that instead.
            let restore = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                waiting = nil
                putBack(previous, on: pasteboard, ifStill: ours)
            }
            waiting = (previous, restore)
        }
        return .pasted
    }

    /// The clipboard to give back, and the task that will.
    private static var waiting: (previous: [NSPasteboardItem], restore: Task<Void, Never>)?

    /// Set by the app: closes satz's menu bar panel.
    static var closeMenus: @MainActor () -> Void = {}

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

    /// The app comes to the front before ⌘V, and ⌘V waits until it is
    /// there: after a fixed 120 ms it sometimes went to whatever app was in
    /// front instead. False if it never comes.
    private static func bringForward(_ origin: NSRunningApplication) -> Bool {
        let isFront = { NSWorkspace.shared.frontmostApplication?.processIdentifier == origin.processIdentifier }
        if isFront() { return true }
        origin.activate()
        waitUntil(timeout: 1, isFront)
        guard isFront() else { return false }
        // Front is not yet the key window taking keys: a beat more.
        waitUntil(timeout: 0.05) { false }
        return true
    }

    /// The window and field the dictation started in, if the user went to
    /// another window of the same app meanwhile. False only when that window
    /// is gone or will not come forward; apps that do not say where their
    /// keyboard is are left as they are.
    private static func bringBack(window: AXUIElement?, field: AXUIElement?, in origin: NSRunningApplication) -> Bool {
        guard let window else { return true }
        AXUIElementSetMessagingTimeout(window, 0.25)
        let app = AXUIElementCreateApplication(origin.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let focusedWindow = { () -> AXUIElement? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        guard let now = focusedWindow() else { return true }
        if CFEqual(now, window) { return true }
        // Still there? A closed window answers no more.
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        waitUntil(timeout: 0.5) { focusedWindow().map { CFEqual($0, window) } ?? false }
        guard focusedWindow().map({ CFEqual($0, window) }) ?? false else { return false }
        if let field {
            AXUIElementSetMessagingTimeout(field, 0.25)
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            waitUntil(timeout: 0.05) { false }
        }
        return true
    }

    /// Lets the main run loop go on (activation and window changes arrive on
    /// it) until the condition holds or the time is up.
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
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

    /// The key that types "v" with ⌘ in the current keyboard layout. Paste is
    /// ⌘ and the letter, not the place: on Dvorak the US V key is K, and ⌘K
    /// went out instead.
    private static func keyForCommandV() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return CGKeyCode(kVK_ANSI_V) }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return CGKeyCode(kVK_ANSI_V) }
            for code in 0 ..< 128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) { return CGKeyCode(code) }
            }
            return CGKeyCode(kVK_ANSI_V)
        }
    }

    private static func sendCommandV() {
        // .combinedSessionState so the event carries the real modifier state of
        // the session rather than a private one, which some applications check.
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = keyForCommandV()

        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
