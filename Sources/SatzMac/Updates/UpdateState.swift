import Observation

/// Sparkle owns verification and replacement. This owns the user's choice
/// and the gap between finishing a dictation and starting a restart.
@MainActor @Observable final class UpdateState {
    enum Stage { case idle, checking, available, downloading, extracting, waiting, restarting, current, failed }
    private(set) var stage: Stage = .idle
    private(set) var visible = false
    private(set) var version = ""
    var progress: Double?
    var informationOnly = false
    var busy = false { didSet { resumeWhenSafe() } }
    var canBeginDictation: Bool { stage != .restarting }
    @ObservationIgnored var check: () -> Void = {}
    @ObservationIgnored var userRequestedInstall: () -> Void = {}
    @ObservationIgnored var userCancelledInstall: () -> Void = {}
    @ObservationIgnored var canProceed: () -> Bool = { true }
    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var waitingForDownload = false

    func found(version: String) {
        self.version = version
        stage = .available
        visible = true
    }

    func opened() { if stage != .idle && stage != .checking { visible = true } }
    func later() { visible = false }

    /// Called only by the Update button, never by a background check.
    func install() {
        guard stage == .available else { return }
        pending = { [weak self] in
            self?.waitingForDownload = false
            self?.stage = .downloading
            self?.userRequestedInstall()
        }
        stage = .waiting
        waitingForDownload = true
        resumeWhenSafe()
    }

    func downloading(cancel: @escaping () -> Void) {
        cancellation = cancel
        progress = nil
        stage = .downloading
        visible = true
    }

    func downloadingVersion(_ version: String) { self.version = version; stage = .downloading }

    func extracting() { cancellation = nil; stage = .extracting; progress = nil }

    func ready(cancel: @escaping () -> Void = {}, restart: @escaping () -> Void) {
        cancellation = cancel
        pending = { [weak self] in
            // Lock before invoking Sparkle: no shortcut can open a mic while
            // the eventual termination event is on its way.
            self?.stage = .restarting
            restart()
        }
        stage = .waiting
        visible = true
        resumeWhenSafe()
    }

    private func resumeWhenSafe() {
        guard !busy, canProceed(), let pending else { return }
        self.pending = nil
        pending()
    }

    func cancel() {
        let cancel = cancellation
        let returnToNotice = waitingForDownload
        clear()
        stage = returnToNotice ? .available : .idle
        visible = returnToNotice
        userCancelledInstall()
        cancel?()
    }

    func failed() { clear(); stage = .failed; visible = true }
    func checking(userInitiated: Bool) { stage = .checking; visible = userInitiated }
    func current(userInitiated: Bool) { clear(); stage = .current; visible = userInitiated }

    func finishedSession() {
        clear()
        if stage != .failed && stage != .current && stage != .available { stage = .idle; visible = false }
    }

    private func clear() { pending = nil; cancellation = nil; progress = nil; waitingForDownload = false }
}
