import Foundation

/// Why a text was not cleaned up. The original is pasted every time; the
/// reason goes to the log, the history entry and the card's notice.
public enum CleanupFailure: Error, Equatable, Sendable {
    case noKey
    case keyRejected
    case noCredit
    case modelNotFound
    case tooManyRequests
    /// Another 4xx, with its status.
    case refused(Int)
    case providerError
    case notReachable
    case tooSlow
    /// The guard: the answer did not look like the dictation.
    case rejected
    case empty
    /// The answer hit its token budget: the end of the dictation is missing,
    /// and the guard lets "Leicht" keep 55 % of the words, so it would pass.
    case cutOff
    /// The model said no (Anthropic's `stop_reason: refusal`, OpenAI's `refusal`).
    case answerRefused
    case appleOff
    case tooLongForApple
    case noAddress
    case noModel
    case noPrompt

    /// Two or three words, the same on every surface.
    public func short(in language: Language = .current) -> String {
        let english = language == .english
        return switch self {
        case .noKey: english ? "No key" : "Schlüssel fehlt"
        case .keyRejected: english ? "Key rejected" : "Schlüssel abgelehnt"
        case .noCredit: english ? "No credit" : "Kein Guthaben"
        case .modelNotFound: english ? "Model not found" : "Modell nicht gefunden"
        case .tooManyRequests: english ? "Too many requests" : "Zu viele Anfragen"
        case .refused(let status): english ? "Request refused (\(status))" : "Anfrage abgelehnt (\(status))"
        case .providerError: english ? "Provider error" : "Anbieter-Fehler"
        case .notReachable: english ? "Not reachable" : "Nicht erreichbar"
        case .tooSlow: english ? "Too slow" : "Zu langsam"
        case .rejected: english ? "Answer rejected" : "Antwort verworfen"
        case .empty: english ? "Empty answer" : "Leere Antwort"
        case .cutOff: english ? "Answer cut off" : "Antwort abgeschnitten"
        case .answerRefused: english ? "Answer refused" : "Antwort verweigert"
        case .appleOff: english ? "Apple Intelligence off" : "Apple Intelligence aus"
        case .tooLongForApple: english ? "Too long for Apple" : "Zu lang für Apple"
        case .noAddress: english ? "No address" : "Adresse fehlt"
        case .noModel: english ? "No model" : "Modell fehlt"
        case .noPrompt: english ? "No prompt" : "Kein Prompt"
        }
    }

    /// For the log and test mode's state file: stable, never translated.
    public var code: String {
        switch self {
        case .noKey: "no-key"
        case .keyRejected: "key-rejected"
        case .noCredit: "no-credit"
        case .modelNotFound: "model-not-found"
        case .tooManyRequests: "too-many-requests"
        case .refused(let status): "refused-\(status)"
        case .providerError: "provider-error"
        case .notReachable: "not-reachable"
        case .tooSlow: "too-slow"
        case .rejected: "rejected"
        case .empty: "empty"
        case .cutOff: "cut-off"
        case .answerRefused: "answer-refused"
        case .appleOff: "apple-off"
        case .tooLongForApple: "too-long-for-apple"
        case .noAddress: "no-address"
        case .noModel: "no-model"
        case .noPrompt: "no-prompt"
        }
    }

    /// An HTTP status that is not a success.
    public static func from(status: Int, body: Data = Data()) -> CleanupFailure {
        switch status {
        case 401, 403: return .keyRejected
        case 402: return .noCredit
        case 404: return .modelNotFound
        // OpenAI says 429 for an empty account too.
        case 429: return String(decoding: body, as: UTF8.self).contains("insufficient_quota") ? .noCredit : .tooManyRequests
        // Google answers a key it does not know with 400 INVALID_ARGUMENT.
        case 400 where String(decoding: body, as: UTF8.self).contains("API_KEY_INVALID"): return .keyRejected
        case 400 ..< 500: return .refused(status)
        default: return .providerError
        }
    }

    public static func from(_ error: URLError) -> CleanupFailure {
        error.code == .timedOut ? .tooSlow : .notReachable
    }
}

/// What came of one cleanup: the text to paste, and how it went.
public struct CleanupResult: Sendable, Equatable {
    /// The cleaned text, or the original after a failure.
    public let text: String
    /// nil when it worked.
    public let failure: CleanupFailure?
    /// The model's answer, cleaned of tags and quotes, also when the guard
    /// threw it away ("Ausprobieren" shows it). Never logged.
    public let cleaned: String?
    /// From sending to the answer; nil when nothing was sent.
    public let seconds: Double?
    /// What it cost, where known: OpenRouter's `usage.cost`, else the tokens
    /// counted at the catalog's price.
    public let dollars: Double?
    /// The status and the provider's short message, for the log. Never the
    /// text, the answer or the key.
    public let detail: String?
    /// Who was asked, for the log and test mode.
    public var provider: CleanupProvider?
    public var model: String?

    public init(text: String, failure: CleanupFailure? = nil, cleaned: String? = nil, seconds: Double? = nil,
                dollars: Double? = nil, detail: String? = nil) {
        self.text = text
        self.failure = failure
        self.cleaned = cleaned
        self.seconds = seconds
        self.dollars = dollars
        self.detail = detail
    }

    /// What a cleanup that was cancelled gives back: the original, with no
    /// time and no price, so it counts as no measurement. Whoever cancelled
    /// it does not read it (Session drops the answer of a discarded
    /// dictation); were it read, it says the original was not cleaned.
    public static func cancelled(_ original: String) -> CleanupResult {
        CleanupResult(text: original, failure: .notReachable, detail: "cancelled")
    }

    /// The model answered, well or not: its time says how fast it is. A
    /// failed request's time says nothing about the model.
    public var answered: Bool {
        guard seconds != nil else { return false }
        switch failure {
        case nil, .rejected?, .empty?, .cutOff?, .answerRefused?: return true
        default: return false
        }
    }

    /// "ok" or the short reason, as the history keeps it.
    public func outcome(in language: Language = .current) -> String {
        failure?.short(in: language) ?? "ok"
    }
}
