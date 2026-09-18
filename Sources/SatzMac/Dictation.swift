import AppKit
import SatzKit

/// The whole act: record, transcribe, deliver.
///
/// Every path ends with the pill either gone or showing a reason it is still
/// there. Nothing is allowed to leave the user watching an indicator that will
/// never resolve.
@MainActor
final class Dictation {

    private let pill: PillController
    private var recorder: AudioRecorder?
    private var transcriber = Transcriber()

    var isRecording: Bool { recorder != nil }

    init(pill: PillController) {
        self.pill = pill
    }

    func toggle() async {
        if isRecording {
            await finish()
        } else {
            await start()
        }
    }

    func cancel() {
        recorder?.cancel()
        recorder = nil
        dismiss()
    }

    // MARK: - Steps

    private func start() async {
        let recorder = AudioRecorder()
        recorder.onLevel = { [weak self] level in
            self?.pill.recording.push(level: level)
        }

        pill.recording.begin()
        pill.show()

        do {
            try await recorder.start()
            self.recorder = recorder
        } catch {
            self.recorder = nil
            report(error.localizedDescription)
        }
    }

    private func finish() async {
        guard let recorder else { return }
        self.recorder = nil

        pill.recording.transcribing()
        pill.resize()

        // finish() holds the microphone open for its tail before returning,
        // which is what keeps the last word.
        guard let audio = await recorder.finish() else {
            dismiss()   // cancelled, or nothing was said
            return
        }

        guard let key = Secrets.read(), !key.isEmpty else {
            report(Transcriber.Failure.noKey.localizedDescription ?? "Kein Schlüssel.")
            return
        }

        do {
            let text = try await transcriber.transcribe(wav: audio, apiKey: key)
            deliver(text)
        } catch {
            report(error.localizedDescription)
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            dismiss()   // nothing was said; say nothing about it
            return
        }
        switch Paster.deliver(text) {
        case .pasted:
            dismiss()
        case .clipboardOnly(let reason):
            // The text is safe on the clipboard. Say so rather than vanishing,
            // or it reads as the transcript having been lost.
            report(reason)
        }
    }

    // MARK: - Pill

    private func report(_ message: String) {
        Log.note(message)
        pill.recording.fail(message)
        pill.resize()
        Task {
            try? await Task.sleep(for: .seconds(5))
            // Only clear if nothing new started in the meantime.
            if !isRecording { dismiss() }
        }
    }

    private func dismiss() {
        pill.hide()
        pill.recording.reset()
    }
}
