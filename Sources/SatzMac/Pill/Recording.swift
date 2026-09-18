import Foundation
import Observation

/// What the pill is currently showing.
public enum Phase: Equatable, Sendable {
    case idle
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

    func begin() {
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
