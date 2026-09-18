import AppKit
import SatzKit

/// The whole act: record, transcribe, deliver.
///
/// The state machine is explicit and every transition happens synchronously
/// before any `await`. An implicit "are we recording" derived from an optional
/// is not enough: opening the microphone can sit behind a permission dialog for
/// as long as the user leaves it up, and an upload takes seconds. During both
/// windows a second press of the shortcut arrives, and it must not start a
/// second recording on top of the first.
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
    private var transcriber = Transcriber()
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

    init(pill: PillController, preferences: Preferences, history: History) {
        self.pill = pill
        self.preferences = preferences
        self.history = history
    }

    func toggle() async {
        switch state {
        case .idle:
            await start()
        case .listening:
            await finish()
        case .starting, .transcribing:
            // Deliberately nothing. A press here used to start a second
            // recording on top of the first.
            break
        }
    }

    func cancel() {
        generation += 1
        switch state {
        case .listening(let recorder):
            recorder.cancel()
        case .transcribing(let task):
            task.cancel()
        case .starting, .idle:
            break
        }
        state = .idle
        releaseEscape()
        dismiss()
    }

    // MARK: - Steps

    private func start() async {
        // Checked before recording rather than after. Discovering there is no
        // key only once you have finished speaking loses the whole message.
        // Presence only: reading the secret itself can raise a Keychain prompt,
        // and the moment the user presses the shortcut is the worst time for one.
        guard Secrets.exists() else {
            report(Transcriber.Failure.noKey.message)
            return
        }

        generation += 1
        let mine = generation
        state = .starting
        origin = NSWorkspace.shared.frontmostApplication
        pill.recording.starting()
        pill.show()
        holdEscape()

        let recorder = AudioRecorder()
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
            await self?.transcribe(recorder, generation: mine)
        }
        state = .transcribing(task)
        pill.recording.transcribing()
        pill.resize()
        releaseEscape()
    }

    private func transcribe(_ recorder: AudioRecorder, generation mine: Int) async {
        // finish() holds the microphone open for its tail before returning,
        // which is what keeps the last word.
        let audio = await recorder.finish()
        guard mine == generation, !Task.isCancelled else { return }

        guard let audio else {
            settle()
            return
        }
        guard let key = Secrets.read(), !key.isEmpty else {
            settle()
            report(Transcriber.Failure.noKey.message)
            return
        }

        do {
            // Read at send time, so an edit in the settings window applies to
            // the very next dictation.
            transcriber.settings.vocabulary = preferences.vocabulary
            let text = try await transcriber.transcribe(wav: audio, apiKey: key)
            guard mine == generation, !Task.isCancelled else { return }
            settle()
            deliver(text)
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            settle()
            report(error.localizedDescription)
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            report("Nichts gehört.")
            return
        }
        // Kept before pasting, so a paste that lands somewhere unexpected is
        // still recoverable from the settings window.
        history.add(text)
        switch Paster.deliver(text, into: origin) {
        case .pasted:
            dismiss()
        case .clipboardOnly(let reason):
            // The text is safe on the clipboard. Say so rather than vanishing,
            // which would read as the transcript having been lost.
            report(reason)
        }
    }

    private func settle() {
        state = .idle
    }

    // MARK: - Escape

    private func holdEscape() {
        escape = try? HotKey(.escape) { [weak self] in self?.cancel() }
    }

    private func releaseEscape() {
        escape = nil
    }

    // MARK: - Pill

    private func report(_ message: String) {
        Log.note(message)
        pill.recording.fail(message)
        pill.show()          // a failure must be visible even if the pill was hidden
        pill.resize()

        let mine = generation
        Task {
            try? await Task.sleep(for: .seconds(5))
            // Only clear if this is still the failure being shown.
            guard mine == generation, case .idle = state else { return }
            dismiss()
        }
    }

    private func dismiss() {
        pill.hide()
        pill.recording.reset()
    }
}
