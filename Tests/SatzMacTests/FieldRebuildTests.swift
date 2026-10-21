import AppKit
import Testing
@testable import SatzMac

// 20.10.: three of ~45 dictations into the Claude app ended on the clipboard
// with "the text field could not be selected again", the keyboard still in
// the composer. Electron apps rebuild their accessibility objects (Chromium
// switches the tree off when nobody asks and builds it again): the element
// captured at the start is gone, and an identical one has the keyboard. The
// stand-in below plays such an app; no other app's windows are touched.

@MainActor
private final class RebuildingKeyboard: KeyboardPlace {
    static let window = AXUIElementCreateApplication(11)
    static let captured = AXUIElementCreateApplication(12)
    static let rebuilt = AXUIElementCreateApplication(13)
    static let inner = AXUIElementCreateApplication(14)
    static let elsewhere = AXUIElementCreateApplication(15)

    var keyboardIn: AXUIElement
    var gone: [AXUIElement] = []
    private var printList: [(AXUIElement, Paster.FieldPrint)] = []
    private var parentList: [(AXUIElement, AXUIElement)] = []

    func setPrint(_ print: Paster.FieldPrint, of element: AXUIElement) { printList.append((element, print)) }
    func setParent(_ parent: AXUIElement, of element: AXUIElement) { parentList.append((element, parent)) }

    init(keyboardIn: AXUIElement) { self.keyboardIn = keyboardIn }

    var focusedWindow: AXUIElement? { Self.window }
    var focusedField: AXUIElement? { keyboardIn }
    func exists(_ element: AXUIElement) -> Bool { !gone.contains { CFEqual($0, element) } }
    func bringForward(_ window: AXUIElement) {}
    func focus(_ field: AXUIElement) { _ = requestFocus(field) }
    /// A gone element takes no request; a live one does.
    func requestFocus(_ field: AXUIElement) -> Bool {
        guard exists(field) else { return false }
        keyboardIn = field
        return true
    }
    func fingerprint(of element: AXUIElement) -> Paster.FieldPrint? { printList.last { CFEqual($0.0, element) }?.1 }
    func parent(of element: AXUIElement) -> AXUIElement? { parentList.last { CFEqual($0.0, element) }?.1 }
}

private let composer = Paster.FieldPrint(role: "AXTextArea", subrole: nil, identifier: nil,
                                         frame: CGRect(x: 400, y: 900, width: 720, height: 56))

@Suite(.serialized) @MainActor
struct FieldRebuildTests {
    private typealias K = RebuildingKeyboard

    @Test func aRebuiltFieldInTheSamePlaceIsPastedInto() {
        let keyboard = K(keyboardIn: K.rebuilt)
        keyboard.gone = [K.captured]
        keyboard.setPrint(composer, of: K.rebuilt)
        Paster.remember(composer, of: K.captured)
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: keyboard) == .restored)
    }

    @Test func aRebuiltFieldThatGrewUpwardsIsStillTheSameField() {
        // The composer grows from its bottom edge while text is in it.
        let keyboard = K(keyboardIn: K.rebuilt)
        keyboard.gone = [K.captured]
        var taller = composer
        taller.frame = CGRect(x: 400, y: 860, width: 720, height: 96)
        keyboard.setPrint(taller, of: K.rebuilt)
        Paster.remember(composer, of: K.captured)
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: keyboard) == .restored)
    }

    @Test func aRebuiltFormWithTheKeyboardInAnotherFieldIsStillRefused() {
        // F05: the page redrew its form and another field has the keyboard.
        let keyboard = K(keyboardIn: K.elsewhere)
        keyboard.gone = [K.captured]
        keyboard.setPrint(Paster.FieldPrint(role: "AXTextField", subrole: nil, identifier: nil,
                                            frame: CGRect(x: 400, y: 120, width: 300, height: 24)), of: K.elsewhere)
        Paster.remember(composer, of: K.captured)
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: keyboard) == .fieldRefused)
    }

    @Test func aSameLookingFieldIsRefusedWhileTheCapturedOneStillExists() {
        // Alive, it would have taken the request; that it did not means the
        // keyboard is somewhere it should not be.
        let keyboard = K(keyboardIn: K.rebuilt)
        keyboard.setPrint(composer, of: K.rebuilt)
        Paster.remember(composer, of: K.captured)
        keyboard.gone = []
        // A captured field that refuses although it exists:
        @MainActor final class Refusing: KeyboardPlace {
            let base: RebuildingKeyboard
            init(_ base: RebuildingKeyboard) { self.base = base }
            var focusedWindow: AXUIElement? { base.focusedWindow }
            var focusedField: AXUIElement? { base.focusedField }
            func exists(_ element: AXUIElement) -> Bool { true }
            func bringForward(_ window: AXUIElement) {}
            func focus(_ field: AXUIElement) {}
            func requestFocus(_ field: AXUIElement) -> Bool { false }
            func fingerprint(of element: AXUIElement) -> Paster.FieldPrint? { base.fingerprint(of: element) }
        }
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: Refusing(keyboard)) == .fieldRefused)
    }

    @Test func aGoneFieldWithNothingRememberedIsRefused() {
        let keyboard = K(keyboardIn: K.rebuilt)
        keyboard.gone = [K.captured]
        keyboard.setPrint(composer, of: K.rebuilt)
        Paster.forget(K.captured)
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: keyboard) == .fieldRefused)
    }

    @Test func aFieldWithAnIdentifierMatchesOnlyThatIdentifier() {
        let keyboard = K(keyboardIn: K.rebuilt)
        keyboard.gone = [K.captured]
        var named = composer
        named.identifier = "prompt"
        var other = composer
        other.identifier = "search"
        keyboard.setPrint(other, of: K.rebuilt)
        Paster.remember(named, of: K.captured)
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: keyboard) == .fieldRefused)
    }

    @Test func theKeyboardInsideTheCapturedFieldCountsAsTheField() {
        // Some web views name a part of the editor as focused, not the editor.
        let keyboard = K(keyboardIn: K.inner)
        keyboard.setParent(K.captured, of: K.inner)
        @MainActor final class Sticky: KeyboardPlace {
            let base: RebuildingKeyboard
            init(_ base: RebuildingKeyboard) { self.base = base }
            var focusedWindow: AXUIElement? { base.focusedWindow }
            var focusedField: AXUIElement? { base.focusedField }
            func exists(_ element: AXUIElement) -> Bool { true }
            func bringForward(_ window: AXUIElement) {}
            func focus(_ field: AXUIElement) {}
            /// Accepted, and the app goes on naming the inner part.
            func requestFocus(_ field: AXUIElement) -> Bool { true }
            func parent(of element: AXUIElement) -> AXUIElement? { base.parent(of: element) }
        }
        #expect(Paster.restoreKeyboard(window: K.window, field: K.captured, in: Sticky(keyboard)) == .restored)
    }

    @Test func printsMatchByPlaceNotByObject() {
        var moved = composer
        moved.frame = CGRect(x: 400, y: 300, width: 720, height: 56)
        #expect(composer.matches(composer))
        #expect(!composer.matches(moved))
        var otherRole = composer
        otherRole.role = "AXTextField"
        #expect(!composer.matches(otherRole))
        var unknown = composer
        unknown.frame = nil
        #expect(!composer.matches(unknown))
    }
}
