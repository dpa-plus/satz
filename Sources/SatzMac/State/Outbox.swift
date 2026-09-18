import AppKit
import Observation

/// A recording that could not be transcribed, kept so it can be sent again.
///
/// Losing thirty seconds of speech to a dropped connection is the worst thing a
/// dictation tool can do. The audio stays here, in memory only, until it is
/// sent successfully or the user throws it away.
@MainActor
@Observable
final class Outbox {

    struct Pending {
        let audio: Data
        /// Where the text was meant to go.
        let origin: NSRunningApplication?
        /// Short, shown as the problem's title.
        let reason: String

        /// Length of the recording, from the WAV's size: 16 kHz, 16-bit, mono.
        var duration: TimeInterval {
            Double(max(0, audio.count - 44)) / 32_000
        }
    }

    private(set) var pending: Pending?

    init(pending: Pending? = nil) {
        self.pending = pending
    }

    func hold(_ audio: Data, origin: NSRunningApplication?, reason: String) {
        pending = Pending(audio: audio, origin: origin, reason: reason)
    }

    func clear() {
        pending = nil
    }
}
