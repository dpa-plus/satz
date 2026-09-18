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

    func run(with preferences: Preferences) async {
        guard !isRunning else { return }
        guard !preferences.isEndpointMissing else {
            state = .failed("Beim eigenen Anbieter fehlt die Adresse.")
            return
        }
        guard let key = Secrets.read(for: preferences.provider), !key.isEmpty else {
            state = .failed(Transcriber.Failure.noKey.message)
            return
        }
        // Captured now, so the result belongs to the settings the probe started with.
        let settings = preferences.transcriberSettings

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

        do {
            let text = try await Transcriber(settings: settings).transcribe(wav: audio, apiKey: key)
            state = text.isEmpty ? .failed("Nichts gehört.") : .heard(text)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
