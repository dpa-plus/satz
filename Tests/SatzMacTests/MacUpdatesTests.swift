import AppKit
import SatzKit
import Sparkle
import Testing
@testable import SatzMac

@MainActor @Suite struct MacUpdatesTests {
    @Test func restartingRefusesRestoringADiscardedDraftAsWellAsANewRecording() {
        let session = Session(preferences: Preferences(defaults: nil), history: History(), discarded: Discarded())
        session.takesEscape = false
        session.canBegin = { false }
        #expect(!session.canRestore)
        session.restore(Discarded.Snapshot(text: NSAttributedString(string: "A draft"), segments: [:],
                                          activeID: nil, nextID: 1, origin: nil, preview: "A draft"))
        #expect(session.phase == .idle)
        #expect(session.text.length == 0)
        session.discard()
    }

    @Test func cancellingDuringACheckCancelsBeforeAnyArchiveIsDownloaded() {
        let state = UpdateState()
        let driver = MacUpdates(state: state)
        var cancelled = false
        driver.showUserInitiatedUpdateCheck(cancellation: { cancelled = true })
        #expect(state.stage == .checking)
        state.cancel()
        #expect(cancelled)
        #expect(state.stage == .idle)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices == [.dismiss])
    }

    @Test func aReadyUpdateDoesNotInstallWithoutExplicitConsentInThisSession() {
        let state = UpdateState()
        let driver = MacUpdates(state: state)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices == [.dismiss])
        #expect(state.stage == .available)
        state.opened()
        #expect(choices == [.dismiss])
    }
}
