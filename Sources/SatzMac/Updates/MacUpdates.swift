import AppKit
import Sparkle
import SatzKit

/// Sparkle verifies EdDSA, replaces the bundle and relaunches. Finding an
/// update only saves its version; the Update button starts a fresh install check.
@MainActor final class MacUpdates: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    let state: UpdateState
    private var updater: SPUUpdater!
    private var started = false
    private var lastCheck = Date.distantPast
    private var userInitiated = false
    private var userApprovedInstall = false
    private var pendingUserInstall = false
    private var checkCancellation: (() -> Void)?
    private var received: UInt64 = 0
    private var expected: UInt64 = 0
    private let testFeed: URL?
    var openWindow: () -> Void = {}

    static var loopbackTestFeed: URL? {
        guard LaunchMode.current.stateFile != nil,
              Bundle.main.bundleIdentifier != "plus.dpa.satz",
              let value = LaunchMode.argument("--test-update-feed"),
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1"
        else { return nil }
        return url
    }

    init(state: UpdateState, testFeed: URL? = nil) {
        self.state = state
        self.testFeed = testFeed
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        state.check = { [weak self] in self?.checkNow() }
        state.userRequestedInstall = { [weak self] in self?.installRequestedByUser() }
        state.userCancelledInstall = { [weak self] in self?.cancelUserInstall() }
    }

    func start() {
        guard LaunchMode.current == .normal || testFeed != nil else { return }
        do {
            try updater.start()
            started = true
            opened()
        } catch { Log.note("updates: could not start (\((error as NSError).code))") }
    }

    func opened() {
        state.opened()
        guard started, updater.canCheckForUpdates, Date().timeIntervalSince(lastCheck) > 1800 else { return }
        lastCheck = Date()
        userInitiated = false
        updater.checkForUpdatesInBackground()
    }

    func checkNow() {
        openWindow()
        state.opened()
        guard started else { state.failed(); return }
        userInitiated = true
        updater.checkForUpdates()
    }

    func feedURLString(for updater: SPUUpdater) -> String? { testFeed?.absoluteString }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        state.checking(userInitiated: true)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        checkCancellation = nil
        if userApprovedInstall && !appcastItem.isInformationOnlyUpdate {
            state.downloadingVersion(appcastItem.displayVersionString)
            reply(.install)
        } else {
            state.informationOnly = appcastItem.isInformationOnlyUpdate
            state.found(version: appcastItem.displayVersionString)
            // Finish the check. Holding this reply until a future click
            // prevents Sparkle discovering a newer release in the meantime.
            reply(.dismiss)
        }
    }

    private func installRequestedByUser() {
        guard started else { state.failed(); return }
        if state.informationOnly {
            NSWorkspace.shared.open(URL(string: "https://github.com/dpa-plus/satz/releases")!)
            state.finishedSession()
        } else {
            pendingUserInstall = true
            beginUserInstallWhenReady()
        }
    }

    private func beginUserInstallWhenReady() {
        guard pendingUserInstall, !updater.sessionInProgress else { return }
        pendingUserInstall = false
        userApprovedInstall = true
        userInitiated = true
        updater.checkForUpdates()
    }

    private func cancelUserInstall() {
        pendingUserInstall = false
        userApprovedInstall = false
        let cancel = checkCancellation
        checkCancellation = nil
        cancel?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // A click can arrive while the passive discovery check is finishing.
        // Start its requested install only after Sparkle has released that check.
        if pendingUserInstall { Task { @MainActor [weak self] in self?.beginUserInstallWhenReady() } }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if let reason, reason.uintValue == SPUNoUpdateFoundReason.onLatestVersion.rawValue {
            state.current(userInitiated: userInitiated)
        } else if userInitiated { state.failed() }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        state.failed()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        received = 0; expected = 0
        state.downloading(cancel: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = received.addingReportingOverflow(length).partialValue
        if expected > 0 { state.progress = min(1, Double(received) / Double(expected)) }
    }
    func showDownloadDidStartExtractingUpdate() { state.extracting() }
    func showExtractionReceivedProgress(_ progress: Double) { state.progress = min(1, max(0, progress)) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard userApprovedInstall else {
            state.found(version: state.version)
            reply(.dismiss)
            return
        }
        state.ready(cancel: { reply(.skip) }) { reply(.install) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        checkCancellation = nil
        userApprovedInstall = false
        if pendingUserInstall { state.checking(userInitiated: true) }
        else { state.finishedSession() }
    }
    func showUpdateInFocus() { state.opened(); openWindow() }
}
