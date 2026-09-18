import Foundation

/// Drives the pill with synthetic loudness so the interface can be looked at
/// and adjusted without speaking, and without needing microphone access.
///
/// Enabled with `satz --demo`. It touches nothing but the pill's levels.
@MainActor
enum DemoDriver {
    static func run(on recording: Recording) {
        recording.listening()
        Task {
            var tick = 0.0
            while !Task.isCancelled {
                // Two detuned sine waves, so the bars rise and fall unevenly
                // the way speech does rather than pulsing like a metronome.
                let wave = sin(tick) * 0.35 + sin(tick * 2.7) * 0.3 + 0.35
                recording.push(level: Float(max(0, min(1, wave))))
                tick += 0.35
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }
}
