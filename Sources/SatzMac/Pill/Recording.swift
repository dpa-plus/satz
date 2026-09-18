import Foundation
import Observation

/// What the pill is currently showing.
enum Phase: Equatable, Sendable {
    case idle
    /// Microphone is being opened. Possibly behind a permission dialog, so this
    /// can last a while and must not look like it is already recording.
    case starting
    case listening
    case transcribing
    /// The text is on the clipboard but could not be pasted.
    case clipboard
    /// Something went wrong. `canRetry` when the recording was kept.
    case failed(String, canRetry: Bool)
}

/// The state the pill draws itself from. Lives on the main actor because it is
/// only ever read by the interface.
@MainActor
@Observable
final class Recording {
    /// Number of bars in the waveform. Levels scroll in from the right.
    static let barCount = 12

    private(set) var phase: Phase = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: barCount)

    var isVisible: Bool { phase != .idle }

    func starting() {
        levels = Array(repeating: 0, count: Self.barCount)
        phase = .starting
    }

    /// The microphone is live and the bars mean something.
    func listening() {
        levels = Array(repeating: 0, count: Self.barCount)
        phase = .listening
    }

    func push(level: Float) {
        guard phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    func transcribing() {
        phase = .transcribing
    }

    func clipboard() {
        phase = .clipboard
    }

    func fail(_ message: String, canRetry: Bool = false) {
        phase = .failed(message, canRetry: canRetry)
    }

    func reset() {
        phase = .idle
        levels = Array(repeating: 0, count: Self.barCount)
    }
}
