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
        if Double(b.count) < 0.85 * Double(a.count) || longestGap(in: a, against: b) >= 3 || longestGap(in: b, against: a) >= 5 {
            return (plain, false)
        }
        return (prompted, true)
    }

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
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0, run = 0, longest = 0
        while i < a.count {
            if j < b.count, a[i] == b[j] {
                run = 0; i += 1; j += 1
            } else if j < b.count, table[i][j + 1] >= table[i + 1][j] {
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
        let frame = max(1, Int(sampleRate * 0.03))
        let needed = max(1, Int(0.2 / 0.03))
        var levels: [Float] = []
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for k in start ..< start + frame { sum += samples[k] * samples[k] }
            levels.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        guard levels.count >= needed else { return false }
        let threshold = threshold(levels)
        return levels.filter { $0 > threshold }.count >= needed
    }

    /// Where the last 30 ms above the speech level end; nil when nothing is
    /// that loud. Parakeet V3 wrote nothing at all for clear speech cut off
    /// mid-word and followed by quiet (a tenth of a second was enough), and
    /// the same audio up to here came back whole.
    public static func speechEnd(_ samples: [Float], sampleRate: Double = 16_000) -> Int? {
        let frame = max(1, Int(sampleRate * 0.03))
        let levels = stride(from: 0, to: samples.count - frame + 1, by: frame).map { start in
            var sum: Float = 0
            for k in start ..< start + frame { sum += samples[k] * samples[k] }
            return (sum / Float(frame)).squareRoot()
        }
        guard !levels.isEmpty else { return nil }
        let threshold = threshold(levels)
        guard let last = levels.lastIndex(where: { $0 > threshold }) else { return nil }
        return (last + 1) * frame
    }

    private static func threshold(_ levels: [Float]) -> Float {
        let quiet = levels.sorted()[levels.count / 10]
        return min(0.0056, max(0.001, 3 * quiet))
    }
}
