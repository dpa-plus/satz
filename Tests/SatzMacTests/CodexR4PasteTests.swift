import AppKit
import Testing
@testable import SatzMac

// MP-R4-01 of the 14.10. bug hunt: the text field the dictation started in
// kept the keyboard but had become read-only. ⌘V went out, nothing went in,
// and satz said "pasted": the clipboard was given back over the transcript
// and the history marked it as pasted. No other app is touched here: the
// field is a stand-in, the clipboard a private pasteboard, and ⌘V a counter.

private func board() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("plus.dpa.satz.tests.r4.\(UUID().uuidString)"))
}

private func copyByUser(_ text: String, to board: NSPasteboard) {
    board.clearContents()
    board.setString(text, forType: .string)
}

/// One field, as Accessibility describes it, and what ⌘V does to it.
@MainActor
private final class StandInField: KeyboardPlace {
    static let window = AXUIElementCreateApplication(21)
    static let field = AXUIElementCreateApplication(22)

    var editability: Paster.Editability
    /// What the field shows now; nil for a field that shows nothing.
    var shown: Paster.FieldText?
    /// What the field shows once ⌘V has arrived; nil leaves it as it was.
    var afterKeys: Paster.FieldText?
    /// How many looks after ⌘V the change takes to show: a busy app.
    var lateBy = 0
    /// The field stops answering once ⌘V has arrived.
    var silentAfterKeys = false
    var onEditability: (() -> Void)?
    private(set) var keys = 0
    private(set) var asked = 0
    private(set) var reads = 0
    private var readsSinceKeys = 0

    init(_ editability: Paster.Editability, shown: Paster.FieldText? = nil, afterKeys: Paster.FieldText? = nil) {
        self.editability = editability
        self.shown = shown
        self.afterKeys = afterKeys
    }

    var focusedWindow: AXUIElement? { Self.window }
    var focusedField: AXUIElement? { Self.field }
    func exists(_ window: AXUIElement) -> Bool { true }
    func bringForward(_ window: AXUIElement) {}
    func focus(_ field: AXUIElement) {}

    func editability(of field: AXUIElement) -> Paster.Editability {
        asked += 1
        onEditability?()
        return editability
    }

    func text(of field: AXUIElement) -> Paster.FieldText? {
        reads += 1
        guard keys > 0 else { return shown }
        if silentAfterKeys { return nil }
        readsSinceKeys += 1
        if let afterKeys, readsSinceKeys > lateBy { return afterKeys }
        return shown
    }

    func press() { keys += 1 }
}

private let before = Paster.FieldText(characters: 11, selection: NSRange(location: 11, length: 0), value: "FIELD ONE: ")
private let pasted = Paster.FieldText(characters: 29, selection: NSRange(location: 29, length: 0), value: "FIELD ONE: [SATZ AUDIT ALPHA]")

// The clipboard loan is one for the whole app: tests that take it out must
// take turns, or one test's handback gives back another's. So these run
// inside the clipboard's serialized suite (CoreFixMacTests.swift); as a
// suite of their own they ran while its waits were pending and broke them.
extension ClipboardTests {
    @Suite(.serialized) @MainActor
    struct ReadOnlyFieldPasteTests {
        fileprivate typealias F = StandInField

        /// Puts the transcript on `board` over the user's copy and runs the part
        /// of a delivery after the keyboard is back, as `deliver` does.
        private func deliver(into place: StandInField, field: AXUIElement? = F.field, board: NSPasteboard,
                             keepsOnClipboard: Bool = false) -> Paster.Outcome {
            copyByUser("user's own copy", to: board)
            let ours = Paster.put("[SATZ AUDIT ALPHA]", on: board)
            return Paster.paste(ours, on: board, into: field, in: place, keepsOnClipboard: keepsOnClipboard,
                                settle: 0.08, keys: place.press)
        }

        // MARK: The finding: same field, read-only now

        @Test func aReadOnlyFieldThatStaysTheSameIsNotCountedAsPasted() {
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: before)
            let outcome = deliver(into: place, board: board)
            guard case .clipboardOnly(let reason) = outcome else {
                Issue.record("counted as pasted although the field did not change")
                return
            }
            #expect(!reason.isEmpty)
            #expect(place.keys == 1)
        }

        @Test func theTranscriptStaysOnTheClipboardWhenTheFieldDidNotTakeIt() {
            let board = board(); defer { board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: before)
            _ = deliver(into: place, board: board)
            // The handback would have put the user's copy back over the only
            // place the transcript still is.
            Paster.restorePendingNow(on: board)
            #expect(board.string(forType: .string) == "[SATZ AUDIT ALPHA]")
        }

        @Test func aDisabledFieldGetsNoKeystrokeAtAll() {
            let board = board(); defer { board.releaseGlobally() }
            let place = StandInField(.disabled, shown: before)
            let outcome = deliver(into: place, board: board)
            #expect(outcome != .pasted)
            #expect(place.keys == 0)
            Paster.restorePendingNow(on: board)
            #expect(board.string(forType: .string) == "[SATZ AUDIT ALPHA]")
        }

        // MARK: Read-only by its own account, but ⌘V went in: terminals

        @Test func aFieldThatSaysReadOnlyButChangedIsPasted() {
            // A terminal says its text cannot be changed and takes ⌘V all the same.
            let board = board(); defer { board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: before, afterKeys: pasted)
            #expect(deliver(into: place, board: board) == .pasted)
            #expect(place.keys == 1)
            Paster.restorePendingNow(on: board)
            #expect(board.string(forType: .string) == "user's own copy")
        }

        @Test func aChangeThatShowsAMomentLaterStillCounts() {
            let board = board(); defer { board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: before, afterKeys: pasted)
            place.lateBy = 2
            #expect(deliver(into: place, board: board) == .pasted)
            #expect(place.keys == 1)
            Paster.restorePendingNow(on: board)
            #expect(board.string(forType: .string) == "user's own copy")
        }

        @Test func onlyTheCaretMovingIsAChangeToo() {
            // A selection replaced by text of the same length: same count, the caret moved.
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            let selected = Paster.FieldText(characters: 11, selection: NSRange(location: 0, length: 5), value: nil)
            let replaced = Paster.FieldText(characters: 11, selection: NSRange(location: 5, length: 0), value: nil)
            let place = StandInField(.readOnly, shown: selected, afterKeys: replaced)
            #expect(deliver(into: place, board: board) == .pasted)
        }

        @Test func aFieldThatShowsNothingIsTakenAtItsWord() {
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: nil)
            #expect(deliver(into: place, board: board) == .pasted)
            #expect(place.keys == 1)
        }

        @Test func aFieldThatStopsAnsweringAfterTheKeystrokeIsTakenAtItsWord() {
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: before)
            place.silentAfterKeys = true
            #expect(deliver(into: place, board: board) == .pasted)
        }

        // MARK: Editable or silent: as before

        @Test func anEditableFieldIsNotWatched() {
            // Terminals and editors in web views type into a hidden helper field
            // that is emptied after every input: it looks unchanged after a paste
            // that worked. A field that says it is editable is taken at its word.
            let board = board(); defer { board.releaseGlobally() }
            let helper = Paster.FieldText(characters: 0, selection: NSRange(location: 0, length: 0), value: "")
            let place = StandInField(.editable, shown: helper)
            #expect(deliver(into: place, board: board) == .pasted)
            #expect(place.keys == 1)
            #expect(place.reads == 0)
            Paster.restorePendingNow(on: board)
            #expect(board.string(forType: .string) == "user's own copy")
        }

        @Test func aFieldThatSaysNothingIsPastedIntoAsBefore() {
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            let place = StandInField(.unknown, shown: before)
            #expect(deliver(into: place, board: board) == .pasted)
            #expect(place.keys == 1)
            #expect(place.reads == 0)
        }

        @Test func withoutACapturedFieldNothingIsAsked() {
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            let place = StandInField(.disabled, shown: before)
            #expect(deliver(into: place, field: nil, board: board) == .pasted)
            #expect(place.keys == 1)
            #expect(place.asked == 0)
            #expect(place.reads == 0)
        }

        // MARK: Keeping the transcript on the clipboard by choice

        @Test func keptByChoiceAndNotTakenIsStillReportedAsNotPasted() {
            let board = board(); defer { board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: before)
            #expect(deliver(into: place, board: board, keepsOnClipboard: true) != .pasted)
            Paster.restorePendingNow(on: board)
            #expect(board.string(forType: .string) == "[SATZ AUDIT ALPHA]")
        }

        @Test func keptByChoiceAndTakenLeavesTheTranscript() {
            let board = board(); defer { board.releaseGlobally() }
            let place = StandInField(.readOnly, shown: before, afterKeys: pasted)
            #expect(deliver(into: place, board: board, keepsOnClipboard: true) == .pasted)
            Paster.restorePendingNow(on: board)
            #expect(board.string(forType: .string) == "[SATZ AUDIT ALPHA]")
        }

        // MARK: Never twice

        @Test func aNewerClipboardBeforeTheKeystrokeIsNotPastedAsTheTranscript() {
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            copyByUser("user's own copy", to: board)
            let ours = Paster.put("[SATZ AUDIT ALPHA]", on: board)
            // Activation and field restoration let the run loop run. A user
            // copy in that interval belongs to the user, not this delivery.
            copyByUser("newer user copy", to: board)
            let place = StandInField(.editable)
            let outcome = Paster.paste(ours, on: board, into: F.field, in: place,
                                       keepsOnClipboard: false, settle: 0.08, keys: place.press)
            #expect(outcome != .pasted)
            #expect(place.keys == 0)
            #expect(board.string(forType: .string) == "newer user copy")
        }

        @Test func aCancellationBeforeTheKeystrokeSendsNothingAndGivesBackOnlyOurLoan() {
            for newerCopy in [false, true] {
                let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
                copyByUser("user's own copy", to: board)
                let ours = Paster.put("[SATZ AUDIT ALPHA]", on: board)
                var current = true
                let place = StandInField(.editable)
                place.onEditability = {
                    current = false
                    if newerCopy { copyByUser("newer user copy", to: board) }
                }
                let outcome = Paster.paste(ours, on: board, into: F.field, in: place,
                                           keepsOnClipboard: false, shouldPaste: { current }, keys: place.press)
                #expect(outcome != .pasted)
                #expect(place.keys == 0)
                #expect(board.string(forType: .string) == (newerCopy ? "newer user copy" : "user's own copy"))
            }
        }

        @Test func noCaseSendsTheKeystrokeTwice() {
            let cases: [StandInField] = [
                StandInField(.readOnly, shown: before),
                StandInField(.readOnly, shown: before, afterKeys: pasted),
                StandInField(.editable, shown: before),
                StandInField(.unknown),
                StandInField(.disabled, shown: before),
            ]
            for place in cases {
                let board = board()
                _ = deliver(into: place, board: board)
                Paster.restorePendingNow(on: board)
                board.releaseGlobally()
                #expect(place.keys <= 1)
            }
        }

        // MARK: Stand-ins written before these checks

        @Test func aStandInWithoutTheNewQuestionsPastesAsBefore() {
            // FakeKeyboard and StubbornKeyboard answer neither question: the
            // defaults must leave them, and apps like them, as they were.
            final class Older: KeyboardPlace {
                var focusedWindow: AXUIElement? { nil }
                var focusedField: AXUIElement? { nil }
                func exists(_ window: AXUIElement) -> Bool { true }
                func bringForward(_ window: AXUIElement) {}
                func focus(_ field: AXUIElement) {}
            }
            let board = board(); defer { Paster.restorePendingNow(on: board); board.releaseGlobally() }
            copyByUser("user's own copy", to: board)
            let ours = Paster.put("[SATZ AUDIT ALPHA]", on: board)
            var keys = 0
            #expect(Paster.paste(ours, on: board, into: F.field, in: Older(), keepsOnClipboard: false, settle: 0.05, keys: { keys += 1 }) == .pasted)
            #expect(keys == 1)
        }
    }
}

/// What a field's answers come to. The answers are the ones the real views
/// gave on 14.10. (an offscreen NSTextView, NSTextFields and a WKWebView,
/// read through Accessibility from another process).
@MainActor
struct EditabilityRuleTests {

    @Test func anEditableTextViewIsEditable() {
        #expect(Paster.editability(valueSettable: true, insideEditableWeb: false, enabled: nil, role: "AXTextArea") == .editable)
    }

    @Test func aTextViewMadeReadOnlyIsReadOnly() {
        // NSTextView.isEditable = false: AXValue no longer settable, same role.
        #expect(Paster.editability(valueSettable: false, insideEditableWeb: false, enabled: nil, role: "AXTextArea") == .readOnly)
    }

    @Test func aReadOnlyWebTextAreaIsReadOnly() {
        #expect(Paster.editability(valueSettable: false, insideEditableWeb: false, enabled: true, role: "AXTextArea") == .readOnly)
    }

    @Test func aDisabledTextFieldIsDisabled() {
        #expect(Paster.editability(valueSettable: false, insideEditableWeb: false, enabled: false, role: "AXTextField") == .disabled)
    }

    @Test func aPartOfAnEditableWebPageIsEditable() {
        // The keyboard can sit on a part of a rich editor whose own value is
        // not settable; the page says it lies inside something editable.
        #expect(Paster.editability(valueSettable: false, insideEditableWeb: true, enabled: true, role: "AXGroup") == .editable)
    }

    @Test func aHiddenHelperFieldSaysItIsEditable() {
        // The xterm.js-style helper textarea: settable, empty, never shows a paste.
        #expect(Paster.editability(valueSettable: true, insideEditableWeb: false, enabled: true, role: "AXTextArea") == .editable)
    }

    @Test func somethingThatIsNoTextFieldIsUnknown() {
        // A read-only NSTextField turns into static text; a web page's group
        // says nothing settable. Neither is a text field that refused.
        #expect(Paster.editability(valueSettable: false, insideEditableWeb: false, enabled: true, role: "AXStaticText") == .unknown)
        #expect(Paster.editability(valueSettable: false, insideEditableWeb: false, enabled: true, role: "AXGroup") == .unknown)
    }

    @Test func noAnswerIsUnknown() {
        #expect(Paster.editability(valueSettable: nil, insideEditableWeb: false, enabled: nil, role: nil) == .unknown)
        #expect(Paster.editability(valueSettable: nil, insideEditableWeb: false, enabled: nil, role: "AXTextArea") == .unknown)
    }
}
