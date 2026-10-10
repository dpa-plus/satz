import Foundation

/// With a prompt, Whisper sometimes leaves out what does not fit it: an
/// English sentence in a German recording was dropped every time. Its prompt
/// (the word list) is worth having only when the text keeps every word, so
/// the text without one is the check.
public enum WordCheck {
    /// The prompted text, unless it lost words the plain one has. A count
    /// alone was not enough: in a long dictation a dropped sentence still left
    /// 85 % of the words. So the two are lined up word by word, and three
    /// plain words in a row missing from the prompted text mean it dropped
    /// something; a spelling the list fixed changes one word, not three.
    public static func keepEveryWord(prompted: String, plain: String) -> (text: String, usedPrompt: Bool) {
        let a = words(plain), b = words(prompted)
        // Nothing heard: a prompt alone can make Whisper repeat the word list.
        guard !a.isEmpty else { return (plain, false) }
        // Extra words in the prompted text prove nothing: a longer made-up
        // phrase must not beat a sentence it dropped. And five or more words
        // in a row the plain text does not have are something the prompt
        // brought in: it repeated a whole earlier passage once.
        if Double(b.count) < 0.85 * Double(a.count) { return (plain, false) }
        // The lining up needs a table of every plain word against every
        // prompted one: 800 MB for an hour of talking, on top of the loaded
        // model. A dictation that long is not checked, and the text without
        // the prompt is the one that cannot have lost a word.
        guard a.count * b.count <= largestComparison else { return (plain, false) }
        if longestGap(in: a, against: b) >= 3 || longestGap(in: b, against: a) >= 5 {
            return (plain, false)
        }
        return (prompted, true)
    }

    /// Words of the plain text times words of the prompted one that are still
    /// lined up: 4 000 words each, about 27 minutes of talking, 64 MB of table.
    static let largestComparison = 16_000_000

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The longest run of words in `a` that a longest common subsequence with
    /// `b` leaves out.
    static func longestGap(in a: [String], against b: [String]) -> Int {
        guard !a.isEmpty else { return 0 }
        guard !b.isEmpty else { return a.count }
        // One flat table of 4-byte cells, not an array of arrays of 8-byte ones.
        let width = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j] ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var i = 0, j = 0, run = 0, longest = 0
        while i < a.count {
            if j < b.count, a[i] == b[j] {
                run = 0; i += 1; j += 1
            } else if j < b.count, table[i * width + j + 1] >= table[(i + 1) * width + j] {
                j += 1
            } else {
                run += 1; longest = max(longest, run); i += 1
            }
        }
        return longest
    }
}

/// Whether a recording has any speech in it at all. Whisper makes something
/// up for silence ("Vielen Dank.", "Untertitelung des ZDF"), so silence is
/// never sent to it.
public enum SpeechGate {
    /// A fifth of a second of 30 ms frames above -45 dBFS, or, from a quiet
    /// microphone, above -60 dBFS and three times the recording's own quiet
    /// level: a fixed -45 dB alone dropped clear speech from a low-gain
    /// microphone, and steady quiet noise is not speech.
    public static func hasSpeech(_ samples: [Float], sampleRate: Double = 16_000) -> Bool {
        threshold(for: samples, sampleRate: sampleRate) != nil
    }

    /// The level above which a 30 ms frame of this recording is speech; nil
    /// when the recording has none. The recording's own quiet level is part
    /// of it, so it is worked out once, on the whole recording: a piece cut
    /// out of it that holds no silence (a quiet voice over a hum, a long
    /// stretch of talking) read its own words as noise and lost them
    /// (`hasSpeech(_:above:)`).
    public static func threshold(for samples: [Float], sampleRate: Double = 16_000) -> Float? {
        let levels = levels(samples[...], sampleRate: sampleRate)
        guard levels.count >= framesNeeded else { return nil }
        let threshold = threshold(levels)
        return levels.filter { $0 > threshold }.count >= framesNeeded ? threshold : nil
    }

    /// Whether a piece of a recording has speech by that recording's
    /// `threshold`, not by a level worked out from the piece alone.
    public static func hasSpeech(_ piece: ArraySlice<Float>, above threshold: Float, sampleRate: Double = 16_000) -> Bool {
        levels(piece, sampleRate: sampleRate).filter { $0 > threshold }.count >= framesNeeded
    }

    /// Where the last 30 ms above the speech level end; nil when nothing is
    /// that loud. Parakeet V3 wrote nothing at all for clear speech cut off
    /// mid-word and followed by quiet (a tenth of a second was enough), and
    /// the same audio up to here came back whole.
    public static func speechEnd(_ samples: [Float], sampleRate: Double = 16_000) -> Int? {
        let levels = levels(samples[...], sampleRate: sampleRate)
        guard !levels.isEmpty else { return nil }
        return end(of: levels, above: threshold(levels), sampleRate: sampleRate)
    }

    /// Whether a piece is one steady level, like a fan, hiss or hum, rather
    /// than speech. Speech rises and falls with every syllable and pause: its
    /// louder frames (30 ms, the 90th percentile) are 18 to 1500 times the
    /// quieter ones (the 10th) in clips of every kind tried, steady noise is
    /// 1.1 times; twice splits them with room on both sides, and speech only
    /// 6 dB above the fan it is recorded over still passes. `hasSpeech` cannot
    /// tell: it takes anything above -45 dBFS for speech, which a low-gain
    /// microphone needs, and Cohere Transcribe wrote whole sentences for a fan
    /// (the same numbers as desktop/src/core/speech.ts). Under a second there
    /// is too little to judge, and a piece with a silent stretch is not steady.
    public static func isSteady(_ samples: ArraySlice<Float>, sampleRate: Double = 16_000) -> Bool {
        let sorted = levels(samples, sampleRate: sampleRate).sorted()
        guard sorted.count >= 30 else { return false }
        let quiet = sorted[sorted.count / 10]
        return quiet > 0 && sorted[sorted.count * 9 / 10] < 2 * quiet
    }

    /// The same for a piece of a recording, by the recording's `threshold`.
    /// Counted from the start of the piece.
    public static func speechEnd(_ piece: ArraySlice<Float>, above threshold: Float, sampleRate: Double = 16_000) -> Int? {
        end(of: levels(piece, sampleRate: sampleRate), above: threshold, sampleRate: sampleRate)
    }

    private static func end(of levels: [Float], above threshold: Float, sampleRate: Double) -> Int? {
        guard let last = levels.lastIndex(where: { $0 > threshold }) else { return nil }
        return (last + 1) * frameLength(sampleRate)
    }

    /// 30 ms frames above the threshold that make speech: a fifth of a second.
    private static let framesNeeded = max(1, Int(0.2 / 0.03))

    private static func frameLength(_ sampleRate: Double) -> Int { max(1, Int(sampleRate * 0.03)) }

    /// The RMS level of each whole 30 ms frame.
    private static func levels(_ samples: ArraySlice<Float>, sampleRate: Double) -> [Float] {
        let frame = frameLength(sampleRate)
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start + frame <= buffer.count {
                var sum: Float = 0
                for k in start ..< start + frame { sum += buffer[k] * buffer[k] }
                levels.append((sum / Float(frame)).squareRoot())
                start += frame
            }
        }
        return levels
    }

    private static func threshold(_ levels: [Float]) -> Float {
        let quiet = levels.sorted()[levels.count / 10]
        return min(0.0056, max(0.001, 3 * quiet))
    }
}
