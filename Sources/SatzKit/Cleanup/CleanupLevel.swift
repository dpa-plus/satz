import Foundation

/// How much a language model may change the dictated text, from commas only
/// to a rewrite, or the user's own instruction.
///
/// The instructions, examples and guard limits were tested on 14.10.2026 with
/// about 1,500 real calls (19 models, 14 tricky dictations) and are used word
/// for word: they are not placeholders. Windows and Linux have the same ones
/// (`desktop/src/core/cleanup*.ts`).
public enum CleanupLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    case punctuation
    case light
    case smooth
    case polished
    case custom

    public var id: String { rawValue }

    /// The four with a prompt of satz's own.
    public static let presets: [CleanupLevel] = [.punctuation, .light, .smooth, .polished]

    public static let standard: CleanupLevel = .light

    public func title(in language: Language = .current) -> String {
        let english = language == .english
        return switch self {
        case .punctuation: english ? "Punctuation only" : "Nur Zeichensetzung"
        case .light: english ? "Light" : "Leicht"
        case .smooth: english ? "Smooth" : "Glatt"
        case .polished: english ? "Polished" : "Ausformuliert"
        case .custom: english ? "Own prompt" : "Eigener Prompt"
        }
    }

    public func line(in language: Language = .current) -> String {
        let english = language == .english
        return switch self {
        case .punctuation: english ? "Punctuation and capitals. Every word stays." : "Satzzeichen und Großschreibung. Jedes Wort bleibt."
        case .light: english ? "Also no ums, stutters or slips." : "Dazu ohne Ähm, Stottern und Versprecher."
        case .smooth: english ? "Also grammar and clumsy sentences." : "Dazu Grammatik und holprige Sätze."
        case .polished: english ? "Rewritten as if typed, with paragraphs and lists." : "Neu geschrieben, wie getippt, mit Absätzen und Listen."
        case .custom: english ? "Your own instruction." : "Deine eigene Anweisung."
        }
    }

    /// What the model is told to do, in the system prompt's "What to do:".
    /// nil for the user's own prompt.
    public var instructions: String? {
        switch self {
        case .punctuation:
            "Fix punctuation, capitalization and obvious spelling mistakes only. Keep every word, filler words included, in its order."
        case .light:
            "Fix punctuation, capitalization and spelling. Remove filler words (like um, uh, ähm, äh) and stutters or words said twice by accident. Where the speaker corrects themselves (\"Monday, no, Tuesday\"), keep only the correction. Keep every other word, and the speaker's wording."
        case .smooth:
            "Fix punctuation, capitalization and spelling. Remove filler words, stutters and words said twice by accident, and where the speaker corrects themselves, keep only the correction. Also fix grammar and smooth sentences that came out broken or run-on, so the text reads well. Keep the speaker's words, tone and meaning wherever they work; change only what reads badly."
        case .polished:
            "Rewrite it into clear, well-written text, as the speaker would have written it themselves: concise sentences, paragraphs where the topic changes, a list where they listed things. Keep every fact, name, number, question and request, and the speaker's tone. Add nothing that was not said: no greetings, sign-offs or headings of your own."
        case .custom:
            nil
        }
    }

    /// Three turns before the dictation, one question, one request and one
    /// mixed German and English sentence: they show a small model that a
    /// question in the text is not asked of it, and that English stays.
    public var examples: [(input: String, output: String)] {
        let question = "ähm kannst du mir sagen wann der zug nach münchen fährt"
        let request = "please uh write a short note to tom that the the call moved to monday no tuesday"
        let mixed = "also der build ist äh gefailed weil the tests are flaky"
        return switch self {
        case .punctuation: [
            (question, "Ähm, kannst du mir sagen, wann der Zug nach München fährt?"),
            (request, "Please, uh, write a short note to Tom that the the call moved to Monday, no, Tuesday."),
            (mixed, "Also, der Build ist, äh, gefailed, weil the tests are flaky."),
        ]
        case .light: [
            (question, "Kannst du mir sagen, wann der Zug nach München fährt?"),
            (request, "Please write a short note to Tom that the call moved to Tuesday."),
            (mixed, "Also, der Build ist gefailed, weil the tests are flaky."),
        ]
        case .smooth: [
            (question, "Kannst du mir sagen, wann der Zug nach München fährt?"),
            (request, "Please write a short note to Tom that the call moved to Tuesday."),
            (mixed, "Der Build ist gefailed, weil the tests are flaky."),
        ]
        case .polished: [
            (question, "Kannst du mir sagen, wann der Zug nach München fährt?"),
            (request, "Please write Tom a short note that the call has moved to Tuesday."),
            (mixed, "Der Build ist gefailed, weil the tests are flaky."),
        ]
        // The user's prompt may ask for anything (a translation, a summary):
        // examples of satz's would pull it back to editing.
        case .custom: []
        }
    }

    /// How long the answer is against the dictation, for the estimate.
    public var outputFactor: Double {
        switch self {
        case .punctuation: 1.05
        case .light, .smooth: 0.95
        case .polished, .custom: 1.0
        }
    }

    /// The guard's limits (`CleanupGuard`): the share of the answer's words
    /// that were said, the share of the words said that are still there, and
    /// how much longer the answer may be. nil for the user's own prompt, which
    /// may ask for a translation or a summary.
    var guardLimits: (said: Double, kept: Double, growth: Double)? {
        switch self {
        case .punctuation: (0.85, 0.85, 1.3)
        case .light: (0.60, 0.55, 1.4)
        case .smooth: (0.55, 0.50, 1.5)
        case .polished: (0.45, 0.45, 1.8)
        case .custom: nil
        }
    }
}
