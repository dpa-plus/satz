import Foundation
import Observation
import SatzKit

/// A short test recording, shown in the settings window instead of pasted.
///
/// It checks the microphone, the key and the connection in one go, and it does
/// not need the paste permission. That makes it the first thing to try after
/// setting satz up, and the quickest way to tell which of the three is broken.
@MainActor
@Observable
final class Probe {

    enum State: Equatable {
        case idle
        case recording(secondsLeft: Int)
        case transcribing
        case heard(String)
        case failed(String)
    }

    static let duration = 4

    private(set) var state: State = .idle

    var isRunning: Bool {
        switch state {
        case .recording, .transcribing: true
        default: false
        }
    }

    init(state: State = .idle) {
        self.state = state
    }

    func run(vocabulary: String) async {
        guard !isRunning else { return }
        guard let key = Secrets.read(), !key.isEmpty else {
            state = .failed(Transcriber.Failure.noKey.message)
            return
        }

        let recorder = AudioRecorder()
        do {
            try await recorder.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        for secondsLeft in stride(from: Self.duration, to: 0, by: -1) {
            state = .recording(secondsLeft: secondsLeft)
            try? await Task.sleep(for: .seconds(1))
        }

        state = .transcribing
        guard let audio = await recorder.finish() else {
            state = .failed("Nichts aufgenommen.")
            return
        }

        var transcriber = Transcriber()
        transcriber.settings.vocabulary = vocabulary
        do {
            let text = try await transcriber.transcribe(wav: audio, apiKey: key)
            state = text.isEmpty ? .failed("Nichts gehört.") : .heard(text)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
