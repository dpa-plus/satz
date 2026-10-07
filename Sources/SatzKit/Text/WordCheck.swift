import Foundation

/// With a prompt, Whisper sometimes leaves out what does not fit it: an
/// English sentence in a German recording was dropped every time. Its prompt
/// (the word list) is worth having only when the text keeps every word, so
/// the text without one is the check.
public enum WordCheck {
    /// The prompted text, unless it has clearly fewer words than the plain one.
    /// A spelling the list fixed may merge or split a word or two.
    public static func keepEveryWord(prompted: String, plain: String) -> (text: String, usedPrompt: Bool) {
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace).count }
        return Double(words(prompted)) >= 0.85 * Double(words(plain)) ? (prompted, true) : (plain, false)
    }
}
