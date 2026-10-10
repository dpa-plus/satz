import Foundation

/// Moonshine, SenseVoice and Canary hear about 30 seconds well and lose
/// words past that, and Parakeet's encoder stops at 400 seconds. A longer
/// recording is split for them at the quietest tenth of a second in the last
/// ten seconds of each window, so no word is cut in half, the same way
/// Windows and Linux feed Whisper (windows.ts). Still one recording and one
/// text: the pieces only go through the model one after another. A dictation
/// under the window stays one piece.
public enum QuietWindows {

    /// The pieces, in order, together exactly `samples`, none longer than
    /// `longest` (30 seconds if not given).
    public static func split(_ samples: [Float], sampleRate: Int = 16_000, longest: Int? = nil) -> [ArraySlice<Float>] {
        // A window of nothing would never move on.
        let longest = max(1, longest ?? 30 * sampleRate)
        let frame = max(1, sampleRate / 10)
        let searched = min(10 * sampleRate, longest)
        var pieces: [ArraySlice<Float>] = []
        var start = 0
        while samples.count - start > longest {
            var cut = start + longest
            var quietest = Float.infinity
            var at = start + longest - searched
            while at + frame <= start + longest {
                var energy: Float = 0
                for index in at ..< at + frame { energy += samples[index] * samples[index] }
                if energy < quietest {
                    quietest = energy
                    cut = at + frame / 2
                }
                at += frame
            }
            pieces.append(samples[start ..< cut])
            start = cut
        }
        pieces.append(samples[start...])
        return pieces
    }
}
