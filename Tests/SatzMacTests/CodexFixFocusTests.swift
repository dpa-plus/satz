import AppKit
import Testing
@testable import SatzMac

// F05 of the 14.10. bug hunt: restoring the dictation's text field was
// attempted but its result never looked at, so ⌘V went into whichever field
// the app still had focused. No other app's windows are touched: the keyboard
// is a stand-in, the elements only identities.

/// One window, the field the dictation started in and another one the app
/// keeps the keyboard in. What the app does with a request is set per test.
@MainActor
private final class StubbornKeyboard: KeyboardPlace {
    static let window = AXUIElementCreateApplication(1)
    static let captured = AXUIElementCreateApplication(2)
    static let other = AXUIElementCreateApplication(3)

    /// The answer Accessibility gives to "focus this field".
    var accepts: Bool
    /// Whether the field really gets the keyboard, whatever the answer was.
    var takesKeyboard: Bool
    /// False for apps that do not name their focused field at all.
    var namesFocusedField: Bool
    private var keyboardIn: AXUIElement = other
    private(set) var requests = 0

    init(accepts: Bool, takesKeyboard: Bool, namesFocusedField: Bool = true) {
        self.accepts = accepts
        self.takesKeyboard = takesKeyboard
        self.namesFocusedField = namesFocusedField
    }

    var focusedWindow: AXUIElement? { Self.window }
    var focusedField: AXUIElement? { namesFocusedField ? keyboardIn : nil }
    func exists(_ window: AXUIElement) -> Bool { true }
    func bringForward(_ window: AXUIElement) {}

    func focus(_ field: AXUIElement) { _ = requestFocus(field) }

    func requestFocus(_ field: AXUIElement) -> Bool {
        requests += 1
        if takesKeyboard { keyboardIn = field }
        return accepts
    }
}

/// Only the old, answerless `focus`: what a stand-in written before the
/// request could fail looks like.
@MainActor
private final class AnswerlessKeyboard: KeyboardPlace {
    var focusedWindow: AXUIElement? { StubbornKeyboard.window }
    var focusedField: AXUIElement? { StubbornKeyboard.other }
    func exists(_ window: AXUIElement) -> Bool { true }
    func bringForward(_ window: AXUIElement) {}
    func focus(_ field: AXUIElement) {}
}

@Suite(.serialized) @MainActor
struct FieldRestoreTests {
    fileprivate typealias K = StubbornKeyboard

    // MARK: Refused: the clipboard instead of the wrong field

    @Test func aFieldThatRefusesTheKeyboardIsNotPastedInto() {
        // The page redrew its form: field A is gone, field B has the keyboard.
        let keyboard = StubbornKeyboard(accepts: false, takesKeyboard: false)
        #expect(!Paster.bringBack(window: K.window, field: K.captured, in: keyboard))
        #expect(keyboard.requests == 1)
    }

    @Test func theReasonIsTheFieldNotTheWindow() {
        let keyboard = StubbornKeyboard(accepts: false, takesKeyboard: false)
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: keyboard) == .fieldRefused)
    }

    @Test func anAcceptedRequestThatMovedNothingIsStillRefused() {
        // The app said yes and kept the keyboard where it was.
        let keyboard = StubbornKeyboard(accepts: true, takesKeyboard: false)
        #expect(!Paster.bringBack(window: K.window, field: K.captured, in: keyboard))
    }

    @Test func aRefusalWithNoFocusedFieldToCheckAgainstCountsAsRefused() {
        let keyboard = StubbornKeyboard(accepts: false, takesKeyboard: false, namesFocusedField: false)
        #expect(!Paster.bringBack(window: K.window, field: K.captured, in: keyboard))
    }

    @Test func aStandInThatCannotAnswerIsStillCheckedAgainstTheFocusedField() {
        #expect(!Paster.bringBack(window: K.window, field: K.captured, in: AnswerlessKeyboard()))
    }

    // MARK: Taken: pasted as before

    @Test func aFieldThatTakesTheKeyboardIsPastedInto() {
        let keyboard = StubbornKeyboard(accepts: true, takesKeyboard: true)
        #expect(Paster.bringBack(window: K.window, field: K.captured, in: keyboard))
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: StubbornKeyboard(accepts: true, takesKeyboard: true)) == .restored)
    }

    @Test func aRequestThatFailedAfterTheKeyboardMovedIsTakenAsRestored() {
        // A timeout in the reply, not in the app: the keyboard is where it should be.
        let keyboard = StubbornKeyboard(accepts: false, takesKeyboard: true)
        #expect(Paster.bringBack(window: K.window, field: K.captured, in: keyboard))
    }

    @Test func anAppThatNamesNoFocusedFieldIsTakenAtItsAnswer() {
        let accepting = StubbornKeyboard(accepts: true, takesKeyboard: true, namesFocusedField: false)
        #expect(Paster.bringBack(window: K.window, field: K.captured, in: accepting))
    }

    @Test func nothingIsAskedWhereTheKeyboardAlreadyIs() {
        let keyboard = StubbornKeyboard(accepts: true, takesKeyboard: true)
        // The user is in the captured field already: no request, so no refusal.
        _ = keyboard.requestFocus(K.captured)
        let before = keyboard.requests
        keyboard.accepts = false
        keyboard.takesKeyboard = false
        #expect(Paster.bringBack(window: K.window, field: K.captured, in: keyboard))
        #expect(keyboard.requests == before)
    }
}
