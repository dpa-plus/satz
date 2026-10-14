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
        let ours = put(text, on: pasteboard)

        if let blocker = whatIsBlockingPaste() {
            // Leave the transcript on the clipboard: it is the fallback.
            return abandon(ours, .clipboardOnly(blocker))
        }
        // Started while satz itself was in front (its settings, say): ⌘V
        // would go to satz, and with no field there the text went nowhere.
        guard let origin else {
            return abandon(ours, .clipboardOnly(de("Auf der Zwischenablage.", en: "On the clipboard.")))
        }
        guard !origin.isTerminated else {
            return abandon(ours, .clipboardOnly(de("Auf der Zwischenablage, die App wurde beendet.", en: "On the clipboard, the app was closed.")))
        }

        if IsSecureEventInputEnabled() { Log.note("paste: Secure Input is on (held by \(secureInputHolder())), sending ⌘V anyway") }
        // satz's own menu had the keyboard (the Insert button, or the menu
        // left open at the end of a dictation): ⌘V went to the menu.
        closeMenus()
        waitUntil(timeout: 0.2) { NSApp.keyWindow == nil }
        guard bringForward(origin) else {
            return abandon(ours, .clipboardOnly(de("Auf der Zwischenablage, die App ließ sich nicht aktivieren.", en: "On the clipboard, the app could not be brought forward.")))
        }
        let keyboard = AppKeyboard(origin)
        switch restoreKeyboard(window: window, field: field, in: keyboard) {
        case .restored: break
        case .windowGone:
            return abandon(ours, .clipboardOnly(de("Auf der Zwischenablage, das Fenster ist nicht mehr da.", en: "On the clipboard, the window is gone.")))
        case .fieldRefused:
            return abandon(ours, .clipboardOnly(de("Auf der Zwischenablage, das Textfeld ließ sich nicht mehr auswählen.", en: "On the clipboard, the text field could not be selected again.")))
        }
        return paste(ours, on: pasteboard, into: field, in: keyboard, keepsOnClipboard: keepsOnClipboard, keys: sendCommandV)
    }

    // MARK: - Whether the field took it

    /// What a field says, just before ⌘V, about taking text.
    enum Editability: Equatable {
        /// Says it is editable.
        case editable
        /// Switched off: nothing goes in, so it gets no ⌘V at all.
        case disabled
        /// Says its text cannot be changed. A text view made read-only says
        /// this (14.10.: it kept the keyboard, nothing went in, and satz
        /// called it pasted), but so do terminals, which take ⌘V all the
        /// same. So ⌘V still goes out, and the field is looked at afterwards.
        case readOnly
        /// Says nothing: ⌘V as always.
        case unknown
    }

    /// What a field shows, compared before and after ⌘V. Any part the
    /// field does not report is nil on both sides.
    struct FieldText: Equatable {
        var characters: Int?
        /// The caret: it moves even when a selection is replaced by text of
        /// the same length.
        var selection: NSRange?
        var value: String?
    }

    /// The text field roles. A field of one of these that says its value
    /// cannot be set is read-only; anything else that says so (a group, a
    /// label) was never a text field to begin with.
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// What a field's answers come to; `AppKeyboard` asks, this decides.
    static func editability(valueSettable: Bool?, insideEditableWeb: Bool, enabled: Bool?, role: String?) -> Editability {
        if valueSettable == true || insideEditableWeb { return .editable }
        if enabled == false { return .disabled }
        guard valueSettable == false, let role, textRoles.contains(role) else { return .unknown }
        return .readOnly
    }

    /// ⌘V into the field the keyboard is back in, then the clipboard handed
    /// back or kept. A field switched off gets no ⌘V; one that says it is
    /// read-only is looked at for up to `settle` seconds, and if nothing in
    /// it changed the transcript was not inserted: it stays on the clipboard.
    ///
    /// Fields that say they are editable are not looked at. In web views a
    /// terminal or a code editor types into a hidden helper field that is
    /// emptied after every input (xterm.js, Monaco): it looks the same after
    /// a paste that worked, and calling that a failure would put the
    /// transcript over the user's clipboard on every dictation there.
    /// `settle` is a second: the wait ends as soon as the field changes (a
    /// local terminal echoes in 0.05 s), and a terminal over a slow ssh link
    /// may take longer than half a second to show the paste, which a shorter
    /// wait took for a refusal and left the transcript over the clipboard.
    /// The handback's own second only starts after it.
    static func paste(_ ours: Int, on pasteboard: NSPasteboard, into field: AXUIElement?, in keyboard: some KeyboardPlace,
                      keepsOnClipboard: Bool, settle: TimeInterval = 1.0, keys: () -> Void) -> Outcome {
        let editability = field.map { keyboard.editability(of: $0) } ?? .unknown
        if editability == .disabled {
            return abandon(ours, .clipboardOnly(de("Auf der Zwischenablage, das Textfeld nimmt gerade keinen Text an.", en: "On the clipboard, the text field does not take text right now.")))
        }
        // Read before ⌘V: afterwards it may already show the paste.
        let before = editability == .readOnly ? field.flatMap { keyboard.text(of: $0) } : nil
        keys()
        if let field, let before {
            waitUntil(timeout: settle) { keyboard.text(of: field) != before }
            // A field that stopped answering is taken at its word, as one
            // that never answered is.
            if keyboard.text(of: field) == before {
                return abandon(ours, .clipboardOnly(de("Auf der Zwischenablage, das Textfeld hat den Text nicht angenommen.", en: "On the clipboard, the text field did not take the text.")))
            }
        }
        if keepsOnClipboard {
            // Nothing to give back: the transcript stays, as chosen.
            if loan?.ours == ours { loan = nil }
        } else {
            handBackSoon(ours, on: pasteboard)
        }
        return .pasted
    }

    // MARK: - The clipboard on loan

    /// What the user had on the clipboard before the transcript took its
    /// place, and whether it is satz's to give back.
    private struct Loan {
        let previous: [NSPasteboardItem]
        /// The pasteboard's change count right after the transcript went on
        /// it. While the count is still this, nobody has copied anything since.
        let ours: Int
        var restore: Task<Void, Never>?
    }
    private static var loan: Loan?

    /// Puts `text` on the clipboard and remembers what was there. Returns the
    /// change count that says the transcript is still what is on it.
    static func put(_ text: String, on pasteboard: NSPasteboard) -> Int {
        // A paste right after another (Insert while a dictation finishes)
        // keeps the clipboard the user had before both: saved now, it was the
        // first transcript, and that came back instead. Only while that
        // transcript is still what is on the clipboard: something copied in
        // between is the user's, and is what comes back this time.
        let previous: [NSPasteboardItem]
        if let loan, pasteboard.changeCount == loan.ours {
            previous = loan.previous
        } else {
            previous = copy(of: pasteboard)
        }
        loan?.restore?.cancel()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount
        loan = Loan(previous: previous, ours: ours)
        return ours
    }

    /// The paste did not go out: the transcript stays on the clipboard as the
    /// fallback, and nothing is given back over it.
    private static func abandon(_ ours: Int, _ outcome: Outcome) -> Outcome {
        if loan?.ours == ours { loan = nil }
        return outcome
    }

    /// Gives the clipboard back a second from now.
    static func handBackSoon(_ ours: Int, on pasteboard: NSPasteboard, after delay: Duration = .seconds(1)) {
        // The loan may be another paste's by now.
        guard loan?.ours == ours else { return }
        // A second, not 400 ms: a busy app (Word, a remote desktop) took ⌘V
        // after the old clipboard was back and pasted that instead.
        loan?.restore = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            restorePendingNow(on: pasteboard)
        }
    }

    /// Gives the clipboard back at once, if a paste has it on loan. Also for
    /// quitting: the second's wait would never end, and the transcript would
    /// stay where the user's own clipboard was.
    static func restorePendingNow(on pasteboard: NSPasteboard = .general) {
        guard let pending = loan else { return }
        pending.restore?.cancel()
        loan = nil
        putBack(pending.previous, on: pasteboard, ifStill: pending.ours)
    }

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

    /// What bringing the keyboard back came to.
    enum Restoration: Equatable {
        /// The keyboard is where the dictation started, or the app does not say
        /// where it is and is left as it is.
        case restored
        /// The window was closed or will not come forward.
        case windowGone
        /// The field would not take the keyboard back, or the app still puts
        /// it somewhere else. ⌘V would type into the wrong field.
        case fieldRefused
    }

    /// Whether the keyboard is back in the window and field the dictation
    /// started in. Apps that do not say where their keyboard is are left as
    /// they are.
    static func bringBack(window: AXUIElement?, field: AXUIElement?, in keyboard: some KeyboardPlace) -> Bool {
        restoreKeyboard(window: window, field: field, in: keyboard) == .restored
    }

    /// Brings the window and field the dictation started in back, if the user
    /// went to another window or field of the same app meanwhile.
    static func restoreKeyboard(window: AXUIElement?, field: AXUIElement?, in keyboard: some KeyboardPlace) -> Restoration {
        guard let window else { return .restored }
        guard let now = keyboard.focusedWindow else { return .restored }
        if !CFEqual(now, window) {
            // Still there? A closed window answers no more.
            guard keyboard.exists(window) else { return .windowGone }
            keyboard.bringForward(window)
            waitUntil(timeout: 0.5) { keyboard.focusedWindow.map { CFEqual($0, window) } ?? false }
            guard keyboard.focusedWindow.map({ CFEqual($0, window) }) ?? false else { return .windowGone }
        }
        // The right window says nothing about the field in it: the user may
        // have clicked into another one while the text was on its way.
        guard let field, !(keyboard.focusedField.map { CFEqual($0, field) } ?? false) else { return .restored }
        // A page that redrew its form has no such field any more, and the
        // request fails while another field has the keyboard. Asking is not
        // enough: ⌘V followed into the wrong field.
        let accepted = keyboard.requestFocus(field)
        waitUntil(timeout: 0.2) { keyboard.focusedField.map { CFEqual($0, field) } ?? false }
        if let focused = keyboard.focusedField { return CFEqual(focused, field) ? .restored : .fieldRefused }
        // The app names no focused field to check against: its answer is all
        // there is.
        return accepted ? .restored : .fieldRefused
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
    /// stays. A clipboard that was empty becomes empty again, so a dictation
    /// does not stay behind on it.
    static func putBack(_ previous: [NSPasteboardItem], on pasteboard: NSPasteboard, ifStill ours: Int) {
        guard pasteboard.changeCount == ours else { return }
        pasteboard.clearContents()
        if !previous.isEmpty { pasteboard.writeObjects(previous) }
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

/// Where the keyboard is in one app, and how to move it. What `Paster` asks
/// of Accessibility, so the order of its steps can be tested without another
/// app's windows.
@MainActor
protocol KeyboardPlace {
    var focusedWindow: AXUIElement? { get }
    var focusedField: AXUIElement? { get }
    /// False once the window has been closed.
    func exists(_ window: AXUIElement) -> Bool
    func bringForward(_ window: AXUIElement)
    func focus(_ field: AXUIElement)
    /// `focus`, saying whether the app took the request.
    func requestFocus(_ field: AXUIElement) -> Bool
    /// Whether the field takes text, as far as the app says.
    func editability(of field: AXUIElement) -> Paster.Editability
    /// What the field shows now; nil where the app does not say.
    func text(of field: AXUIElement) -> Paster.FieldText?
}

extension KeyboardPlace {
    /// A place that cannot tell is taken at its word; `Paster` looks at the
    /// focused field afterwards either way.
    func requestFocus(_ field: AXUIElement) -> Bool {
        focus(field)
        return true
    }

    /// A place that says nothing is pasted into as before these checks.
    func editability(of field: AXUIElement) -> Paster.Editability { .unknown }
    func text(of field: AXUIElement) -> Paster.FieldText? { nil }
}

/// The keyboard of a running app, through Accessibility.
@MainActor
struct AppKeyboard: KeyboardPlace {
    private let app: AXUIElement

    init(_ origin: NSRunningApplication) {
        app = AXUIElementCreateApplication(origin.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
    }

    var focusedWindow: AXUIElement? { element(kAXFocusedWindowAttribute) }
    var focusedField: AXUIElement? { element(kAXFocusedUIElementAttribute) }

    func exists(_ window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.25)
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
    }

    func bringForward(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
    }

    func focus(_ field: AXUIElement) {
        _ = requestFocus(field)
    }

    func requestFocus(_ field: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(field, 0.25)
        return AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    func editability(of field: AXUIElement) -> Paster.Editability {
        AXUIElementSetMessagingTimeout(field, 0.25)
        var settable: DarwinBoolean = false
        let asked = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
        // Browsers mark what lies inside an editable page; the keyboard can
        // sit on a part of a rich editor whose own value is not settable.
        let ancestor = value(of: "AXEditableAncestor", in: field)
        return Paster.editability(valueSettable: asked == .success ? settable.boolValue : nil,
                                  insideEditableWeb: ancestor.map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false,
                                  enabled: value(of: kAXEnabledAttribute, in: field) as? Bool,
                                  role: value(of: kAXRoleAttribute, in: field) as? String)
    }

    func text(of field: AXUIElement) -> Paster.FieldText? {
        AXUIElementSetMessagingTimeout(field, 0.25)
        let characters = value(of: kAXNumberOfCharactersAttribute, in: field) as? Int
        var selection: NSRange?
        if let range = value(of: kAXSelectedTextRangeAttribute, in: field), CFGetTypeID(range) == AXValueGetTypeID() {
            var cf = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &cf) { selection = NSRange(location: cf.location, length: cf.length) }
        }
        // The whole text only while it is short: a terminal's is its entire
        // scrollback, and it is read again every few milliseconds.
        let text = (characters ?? 0) <= 20_000 ? value(of: kAXValueAttribute, in: field) as? String : nil
        guard characters != nil || selection != nil || text != nil else { return nil }
        return Paster.FieldText(characters: characters, selection: selection, value: text)
    }

    private func value(of attribute: String, in field: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
