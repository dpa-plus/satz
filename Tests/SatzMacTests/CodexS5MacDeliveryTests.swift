import AppKit
import SatzKit
import Testing
@testable import SatzMac

@Suite(.serialized) @MainActor
struct MacHistoryDeliveryTests {
    @Test func aHistoryRenameFailureDoesNotMakeDeliveredWordsRetryable() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-history-delivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        // A directory at the destination makes the real rename fail.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let history = History(file: file)
        let discarded = Discarded()
        let session = Session(preferences: Preferences(defaults: nil), history: history, discarded: discarded)
        session.takesEscape = false
        var delivered: [String] = []
        session.pasteText = { text, _, _, _, _, _ in delivered.append(text); return .pasted }
        session.stage(.paused, text: "Synthetic delivered words.")
        session.press()
        for _ in 0..<100 where delivered.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(delivered == ["Synthetic delivered words."])
        #expect(session.phase == .idle)
        #expect(history.entries.first?.text == "Synthetic delivered words.")
        #expect(discarded.last == nil)
        session.retry()
        await Task.yield()
        #expect(delivered == ["Synthetic delivered words."])
        // The failed write must not leave a temporary transcript behind.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".history.json.new").path))
    }

    @Test func aWorkingHistorySaveSurvivesANewInstance() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-history-control-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = History(file: file)
        history.add("Synthetic saved words.", app: nil, pasted: true)
        #expect(History(file: file).entries.first?.text == "Synthetic saved words.")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}

@Suite(.serialized) @MainActor
struct MacDeliveryRecoveryTests {
    @Test func historyOffKeepsExactCleanedOutputForOneExplicitRetry() async {
        _ = NSApplication.shared
        let preferences = Preferences(defaults: nil)
        preferences.cleansText = true
        let history = History(limit: 0)
        let session = Session(preferences: preferences, history: history, discarded: Discarded())
        session.takesEscape = false
        var cleanups = 0
        session.cleaner = { _ in
            cleanups += 1
            return CleanupResult(text: "Synthetic cleaned words.", cleaned: "Synthetic cleaned words.")
        }
        var attempts: [String] = []
        session.pasteText = { text, _, _, _, _, _ in
            attempts.append(text)
            return attempts.count == 1 ? .notPasted("Synthetic clipboard change") : .pasted
        }
        session.stage(.paused, text: "synthetic original words")
        session.press()
        for _ in 0..<100 where attempts.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .failed("Synthetic clipboard change", canRetry: true))
        #expect(session.plainText() == "synthetic original words")
        #expect(history.entries.isEmpty)
        session.retry()
        for _ in 0..<100 where attempts.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(attempts == ["Synthetic cleaned words.", "Synthetic cleaned words."])
        #expect(cleanups == 1)
        #expect(session.phase == .idle)
        #expect(history.entries.isEmpty)
        session.retry()
        await Task.yield()
        #expect(attempts.count == 2)
    }

    @Test func aQueuedStartCannotReplaceAnUndeliveredDraft() async {
        _ = NSApplication.shared
        let session = Session(preferences: Preferences(defaults: nil), history: History(limit: 0), discarded: Discarded())
        session.takesEscape = false
        var attempts = 0
        session.pasteText = { _, _, _, _, _, _ in
            attempts += 1
            if attempts == 1 {
                // The shortcut arrives while activation lets the run loop run.
                session.press()
                return .notPasted("Synthetic clipboard change")
            }
            return .pasted
        }
        session.stage(.paused, text: "Synthetic retained draft.")
        session.press()
        for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .failed("Synthetic clipboard change", canRetry: true))
        #expect(session.plainText() == "Synthetic retained draft.")
        session.retry()
        for _ in 0..<100 where attempts < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .idle)
        #expect(attempts == 2)
    }

    @Test func anEditAfterInterruptionReplacesTheCachedDelivery() async {
        _ = NSApplication.shared
        let preferences = Preferences(defaults: nil)
        preferences.cleansText = true
        let session = Session(preferences: preferences, history: History(limit: 0), discarded: Discarded())
        session.takesEscape = false
        var cleanups = 0
        session.cleaner = { text in
            cleanups += 1
            return CleanupResult(text: "Cleaned \(text)", cleaned: "Cleaned \(text)")
        }
        var attempts: [String] = []
        session.pasteText = { text, _, _, _, _, _ in
            attempts.append(text)
            return attempts.count == 1 ? .notPasted("Synthetic clipboard change") : .pasted
        }
        session.stage(.paused, text: "Original draft.")
        session.press()
        for _ in 0..<100 where attempts.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let range = NSRange(location: 0, length: session.text.length)
        #expect(session.userWillEdit(range))
        session.text.replaceCharacters(in: range, with: "Edited draft.")
        session.userDidEdit()
        session.retry()
        for _ in 0..<100 where attempts.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(attempts == ["Cleaned Original draft.", "Cleaned Edited draft."])
        #expect(cleanups == 2)
        #expect(session.phase == .idle)
    }

    @Test func cancellingDuringKeyboardHandoffPreventsTheDelayedPaste() async {
        _ = NSApplication.shared
        let discarded = Discarded()
        let session = Session(preferences: Preferences(defaults: nil), history: History(limit: 0), discarded: discarded)
        session.takesEscape = false
        session.cardHasKeyboard = { true }
        var attempts = 0
        session.pasteText = { _, _, _, _, _, _ in attempts += 1; return .pasted }
        var hidden = false
        session.onClose = { hidden = true }
        session.stage(.paused, text: "Synthetic cancelled draft.")
        session.press()
        for _ in 0..<100 where !hidden { try? await Task.sleep(for: .milliseconds(1)) }
        session.discard()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(attempts == 0)
        #expect(discarded.last?.preview == "Synthetic cancelled draft.")
        session.undoDiscard()
        #expect(session.plainText() == "Synthetic cancelled draft.")
        session.discard()
    }

    @Test func aDiscardInsideThePasteBoundaryCannotBeReplacedByItsLateOutcome() async {
        _ = NSApplication.shared
        for outcome in [Paster.Outcome.notPasted("Synthetic clipboard change"), .pasted] {
            let discarded = Discarded()
            let history = History()
            let session = Session(preferences: Preferences(defaults: nil), history: history, discarded: discarded)
            session.takesEscape = false
            var attempts = 0
            session.pasteText = { _, _, _, _, _, _ in
                attempts += 1
                session.discard()
                return outcome
            }
            session.stage(.paused, text: "Synthetic discarded draft.")
            session.press()
            for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(session.phase == .discarded)
            #expect(discarded.last?.preview == "Synthetic discarded draft.")
            #expect(history.entries.count == (outcome == .pasted ? 1 : 0))
            if outcome == .pasted { #expect(history.entries.first?.pasted == true) }
            session.retry()
            await Task.yield()
            #expect(attempts == 1)
            #expect(history.entries.count == (outcome == .pasted ? 1 : 0))
            session.discard()
        }
    }

    @Test func aDiscardInsideThePasteBoundaryRevokesPermissionToSendKeys() async {
        _ = NSApplication.shared
        let discarded = Discarded()
        let session = Session(preferences: Preferences(defaults: nil), history: History(limit: 0), discarded: discarded)
        session.takesEscape = false
        var attempts = 0
        var keys = 0
        session.pasteText = { _, _, _, _, _, shouldPaste in
            attempts += 1
            session.discard()
            if shouldPaste() { keys += 1 }
            return .notPasted("Synthetic cancelled delivery")
        }
        session.stage(.paused, text: "Synthetic cancelled draft.")
        session.press()
        for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(keys == 0)
        #expect(session.phase == .discarded)
        #expect(discarded.last?.preview == "Synthetic cancelled draft.")
        session.discard()
    }

    @Test func anEmptyDeliveryStillHonorsAQueuedNewStart() async {
        _ = NSApplication.shared
        let preferences = Preferences(defaults: nil)
        preferences.provider = .custom
        preferences.model = ""
        let session = Session(preferences: preferences, history: History(limit: 0), discarded: Discarded())
        session.takesEscape = false
        var captures = 0
        session.captureFocus = { _ in captures += 1; return (nil, nil) }
        session.stage(.paused)
        session.press()
        session.press()
        for _ in 0..<100 where captures == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(captures == 1)
        session.discard()
    }
}
