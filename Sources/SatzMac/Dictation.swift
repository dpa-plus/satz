import AppKit
import SatzKit

/// The whole act: record, transcribe, deliver.
///
/// The state machine is explicit and every transition happens synchronously
/// before any `await`. Opening the microphone can sit behind a permission
/// dialog for as long as the user leaves it up, and an upload takes seconds;
/// during both windows another press of the shortcut arrives and must not
/// start a second recording on top of the first.
@MainActor
final class Dictation {

    private enum State {
        case idle
        /// Opening the microphone. Ignores the shortcut; cancel still works.
        case starting
        case listening(AudioRecorder)
        /// Uploading. The task is held so cancel can actually stop it.
        case transcribing(Task<Void, Never>)
    }

    private let pill: PillController
    private let preferences: Preferences
    private let history: History
    private let outbox: Outbox
    private var state: State = .idle
    /// Bumped by every start and every cancel. Work resumed after an `await`
    /// compares it and gives up if the world moved on.
    private var generation = 0
    /// Held only while recording, so Escape is not stolen from other apps the
    /// rest of the time.
    private var escape: HotKey?
    /// Where the user was typing when they started, so the transcript goes back
    /// there even if they switched apps while it uploaded.
    private var origin: NSRunningApplication?

    init(pill: PillController, preferences: Preferences, history: History, outbox: Outbox) {
        self.pill = pill
        self.preferences = preferences
        self.history = history
        self.outbox = outbox
    }

    // MARK: - Trigger

    /// The shortcut went down.
    func press() {
        switch preferences.triggerMode {
        case .tap:
            toggle()
        case .hold:
            if case .idle = state { Task { await start() } }
        }
    }

    /// The shortcut came up. Only meaningful while holding to talk.
    func release() {
        guard preferences.triggerMode == .hold else { return }
        switch state {
        case .listening: Task { await finish() }
        // Let go before the microphone even opened: nothing worth sending.
        case .starting: cancel()
        default: break
        }
    }

    func toggle() {
        switch state {
        case .idle: Task { await start() }
        case .listening: Task { await finish() }
        // Deliberately nothing: a press here used to start a second recording.
        case .starting, .transcribing: break
        }
    }

    func cancel() {
        generation += 1
        switch state {
        case .listening(let recorder): recorder.cancel()
        case .transcribing(let task): task.cancel()
        case .starting, .idle: break
        }
        state = .idle
        releaseEscape()
        dismiss()
    }

    // MARK: - Outbox

    /// Sends a kept recording again, to where it was first meant to go.
    func retry() {
        guard case .idle = state, let pending = outbox.pending else { return }
        generation += 1
        let mine = generation
        origin = pending.origin
        pill.recording.transcribing()
        pill.show()
        let task = Task { [weak self] () -> Void in
            await self?.send(pending.audio, generation: mine)
        }
        state = .transcribing(task)
    }

    func discard() {
        outbox.clear()
        if case .failed = pill.recording.phase { dismiss() }
    }

    // MARK: - Steps

    private func start() async {
        // Checked before recording rather than after: discovering there is no
        // key once you have finished speaking loses the whole message. Presence
        // only, because reading the secret can raise a Keychain prompt.
        guard Secrets.exists(for: preferences.provider) else {
            report(Transcriber.Failure.noKey.short)
            return
        }
        guard !preferences.isEndpointMissing else {
            report("Adresse fehlt")
            return
        }

        generation += 1
        let mine = generation
        state = .starting
        origin = NSWorkspace.shared.frontmostApplication
        pill.recording.starting()
        pill.show()
        holdEscape()

        var settings = AudioRecorder.Settings()
        settings.inputDeviceID = InputDevices.id(forUID: preferences.inputDeviceUID)
        let recorder = AudioRecorder(settings: settings)
        recorder.onLevel = { [weak self] level in
            self?.pill.recording.push(level: level)
        }

        do {
            try await recorder.start()
        } catch {
            guard mine == generation else { return }
            state = .idle
            releaseEscape()
            report(error.localizedDescription)
            return
        }

        // Cancelled while the permission dialog was up: stop the microphone we
        // just opened rather than leaving it running invisibly.
        guard mine == generation else {
            recorder.cancel()
            return
        }
        state = .listening(recorder)
        pill.recording.listening()
    }

    private func finish() async {
        guard case .listening(let recorder) = state else { return }

        let mine = generation
        let task = Task { [weak self] () -> Void in
            // finish() holds the microphone open for its tail before returning,
            // which is what keeps the last word.
            guard let audio = await recorder.finish() else {
                self?.settle()
                self?.dismiss()
                return
            }
            await self?.send(audio, generation: mine)
        }
        state = .transcribing(task)
        pill.recording.transcribing()
        pill.resize()
        releaseEscape()
    }

    private func send(_ audio: Data, generation mine: Int) async {
        guard mine == generation, !Task.isCancelled else { return }
        guard let key = Secrets.read(for: preferences.provider), !key.isEmpty else {
            settle()
            outbox.hold(audio, origin: origin, reason: Transcriber.Failure.noKey.short)
            report(Transcriber.Failure.noKey.short, canRetry: true)
            return
        }

        do {
            // Read at send time, so an edit in the settings window applies to
            // the very next dictation.
            let transcriber = Transcriber(settings: preferences.transcriberSettings)
            let text = try await transcriber.transcribe(wav: audio, apiKey: key)
            guard mine == generation, !Task.isCancelled else { return }
            settle()
            outbox.clear()
            deliver(text)
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            settle()
            // Keep the recording. Losing half a minute of speech to a dropped
            // connection is the worst thing a dictation tool can do.
            let reason = (error as? Transcriber.Failure)?.short ?? "Fehler"
            Log.note("transcription failed: \(error.localizedDescription)")
            outbox.hold(audio, origin: origin, reason: reason)
            report(reason, canRetry: true)
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            report("Nichts gehört")
            return
        }
        let outcome = Paster.deliver(text, into: origin)
        history.add(text, app: origin?.localizedName, pasted: outcome == .pasted)
        switch outcome {
        case .pasted:
            dismiss()
        case .clipboardOnly(let reason):
            // Safe on the clipboard. Say so rather than vanishing, which would
            // read as the transcript having been lost.
            Log.note(reason)
            pill.recording.clipboard()
            pill.resize()
            dismissLater(after: .seconds(3))
        }
    }

    private func settle() {
        state = .idle
    }

    // MARK: - Escape

    private func holdEscape() {
        escape = try? HotKey(.escape, onPress: { [weak self] in self?.cancel() })
    }

    private func releaseEscape() {
        escape = nil
    }

    // MARK: - Pill

    private func report(_ message: String, canRetry: Bool = false) {
        Log.note(message)
        pill.recording.fail(message, canRetry: canRetry)
        pill.show()          // a failure must be visible even if the pill was hidden
        pill.resize()
        // A kept recording stays in the menu bar panel, so the pill can go.
        dismissLater(after: .seconds(canRetry ? 8 : 5))
    }

    private func dismissLater(after delay: Duration) {
        let mine = generation
        Task {
            try? await Task.sleep(for: delay)
            guard mine == generation, case .idle = state else { return }
            dismiss()
        }
    }

    private func dismiss() {
        pill.hide()
        pill.recording.reset()
    }
}

extension Transcriber.Failure {
    /// Two or three words, for the pill and the panel's problem title.
    var short: String {
        switch self {
        case .noKey: "Kein Schlüssel"
        case .unauthorized: "Schlüssel abgelehnt"
        case .rateLimited: "Anbieter drosselt"
        case .offline: "Keine Verbindung"
        case .timedOut: "Zeitüberschreitung"
        case .server: "Fehler beim Anbieter"
        case .unreadableResponse: "Antwort unlesbar"
        }
    }
}
