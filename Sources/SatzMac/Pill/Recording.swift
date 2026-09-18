import Foundation
import Observation

/// What the pill is currently showing.
public enum Phase: Equatable, Sendable {
    case idle
    /// Microphone is being opened. Possibly behind a permission dialog, so this
    /// can last a while and must not look like it is already recording.
    case starting
    case listening
    case transcribing
    case failed(String)
}

/// The state the pill draws itself from. Lives on the main actor because it is
/// only ever read by the interface.
@MainActor
@Observable
final class Recording {
    /// Number of bars in the waveform. Levels scroll in from the right.
    static let barCount = 14

    private(set) var phase: Phase = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: barCount)

    var isVisible: Bool { phase != .idle }

    /// The microphone is not live yet. Possibly behind a permission dialog,
    /// so this must not look like it is already recording.
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

    func fail(_ message: String) {
        phase = .failed(message)
    }

    func reset() {
        phase = .idle
        levels = Array(repeating: 0, count: Self.barCount)
    }
}
