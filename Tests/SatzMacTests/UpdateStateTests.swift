import Testing
#if canImport(UpdateLogic)
@testable import UpdateLogic
#else
@testable import SatzMac
#endif

@MainActor @Suite struct UpdateStateTests {
    @Test func aNoticeNeverInstallsUntilTheUserAsks() {
        let state = UpdateState()
        var downloads = 0
        state.userRequestedInstall = { downloads += 1 }
        state.found(version: "0.4.6")
        #expect(state.stage == .available)
        #expect(state.visible)
        #expect(downloads == 0)
        state.later()
        #expect(!state.visible)
        state.opened()
        #expect(state.visible)
        #expect(downloads == 0)
        state.install()
        state.install()
        #expect(downloads == 1)
    }

    @Test func anUpdateRequestedDuringDictationWaitsWithoutDroppingTheRequest() {
        let state = UpdateState()
        var downloads = 0
        state.busy = true
        state.userRequestedInstall = { downloads += 1 }
        state.found(version: "0.4.6")
        state.install()
        #expect(state.stage == .waiting)
        #expect(downloads == 0)
        #expect(state.canBeginDictation)
        state.busy = false
        #expect(downloads == 1)
        #expect(state.stage == .downloading)
    }

    @Test func aNewDictationDuringDownloadDefersRestartAndLocksTheFinalGap() {
        let state = UpdateState()
        var restarts = 0
        state.found(version: "0.4.6")
        state.install()
        state.busy = true
        state.ready { restarts += 1; #expect(!state.canBeginDictation) }
        #expect(restarts == 0)
        #expect(state.stage == .waiting)
        state.busy = false
        state.busy = false
        #expect(restarts == 1)
        #expect(state.stage == .restarting)
        #expect(!state.canBeginDictation)
    }

    @Test func cancellingADeferredRestartPreventsALaterSurpriseRestart() {
        let state = UpdateState()
        var restarts = 0
        var cancels = 0
        state.found(version: "0.4.6")
        state.install()
        state.busy = true
        state.ready(cancel: { cancels += 1 }) { restarts += 1 }
        state.cancel()
        state.busy = false
        #expect(restarts == 0)
        #expect(cancels == 1)
        #expect(state.canBeginDictation)
        #expect(!state.visible)
    }

    @Test func failureReleasesTheRestartLockAndDoesNotPretendToBeCurrent() {
        let state = UpdateState()
        state.ready {}
        #expect(!state.canBeginDictation)
        state.failed()
        #expect(state.canBeginDictation)
        #expect(state.stage == .failed)
        #expect(state.visible)
    }

    @Test func cancellingBeforeDownloadReturnsToTheNoticeWithoutInstallingLater() {
        let state = UpdateState()
        var downloads = 0
        state.userRequestedInstall = { downloads += 1 }
        state.busy = true
        state.found(version: "0.4.6")
        state.install()
        state.cancel()
        state.busy = false
        #expect(downloads == 0)
        #expect(state.stage == .available)
        state.install()
        #expect(downloads == 1)
    }

    @Test func theLiveSessionGateCatchesAnObservationThatHasNotArrivedYet() {
        let state = UpdateState()
        var idle = false
        var restarts = 0
        state.canProceed = { idle }
        state.ready { restarts += 1 }
        #expect(restarts == 0)
        idle = true
        state.busy = false
        #expect(restarts == 1)
    }

    @Test func finishingABackgroundCheckKeepsOnlyTheNoticeAndAllowsNewDiscovery() {
        let state = UpdateState()
        state.found(version: "0.4.6")
        state.finishedSession()
        state.later()
        state.found(version: "0.4.7")
        #expect(state.version == "0.4.7")
        #expect(state.stage == .available)
        #expect(state.visible)
    }

    @Test func checkingIsQuietUntilExplicitlyRequested() {
        let state = UpdateState()
        state.checking(userInitiated: false)
        #expect(!state.visible)
        state.current(userInitiated: false)
        #expect(!state.visible)
        state.checking(userInitiated: true)
        #expect(state.visible)
        state.current(userInitiated: true)
        #expect(state.stage == .current)
        #expect(state.visible)
    }
}
