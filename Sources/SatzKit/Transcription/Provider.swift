import Foundation

/// Where the audio goes to become text.
///
/// Every provider here takes `POST {base}/audio/transcriptions`: a multipart
/// upload in OpenAI's format, or JSON for OpenRouter (see
/// `Transcriber.Format`). That is why supporting another one is a base URL and
/// a default model, and why a custom endpoint works for anything that copies
/// OpenAI's API.
public enum Provider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case groq
    case custom

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .groq: "Groq"
        case .custom: "Eigener"
        }
    }

    /// nil for a custom endpoint, where the user supplies it.
    public var baseURL: URL? {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        case .groq: URL(string: "https://api.groq.com/openai/v1")
        case .custom: nil
        }
    }

    /// The newest transcription model each provider offers, as of writing.
    /// Editable in the settings window, because model lists move faster than
    /// releases of this app.
    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-transcribe"
        // 2.0% word errors on Artificial Analysis in Sept. 2026 against 3.3%
        // for GPT Transcribe, at a third of the price, and it has a clean mode.
        case .openRouter: "microsoft/mai-transcribe-2"
        case .groq: "whisper-large-v3-turbo"
        case .custom: ""
        }
    }

    /// What a key from this provider looks like, shown as the field's placeholder.
    public var keyPlaceholder: String {
        switch self {
        case .openAI: "sk-…"
        case .openRouter: "sk-or-…"
        case .groq: "gsk_…"
        case .custom: "API-Schlüssel"
        }
    }

    /// Each provider keeps its own key, so switching back and forth does not
    /// mean pasting keys again. The OpenAI account name predates providers and
    /// is kept so an existing key is still found.
    public var keychainAccount: String { rawValue }
}
