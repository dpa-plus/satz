import Foundation

/// Where the audio goes to become text.
///
/// OpenAI, OpenRouter, Groq and a custom endpoint take
/// `POST {base}/audio/transcriptions`: a multipart upload in OpenAI's format,
/// or JSON for OpenRouter (see `Transcriber.Format`). That is why supporting
/// another one of those is a base URL and a default model, and why a custom
/// endpoint works for anything that copies OpenAI's API. Microsoft (Azure AI
/// Speech) and Google (the Gemini API) have requests of their own, which is
/// why they are providers and not a base URL. `.local` is the exception: the
/// model runs on this computer, and nothing is sent anywhere.
public enum Provider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case groq
    case microsoft
    case google
    case custom
    case local

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .groq: "Groq"
        case .microsoft: "Microsoft"
        case .google: "Google"
        case .custom: de("Eigener", en: "Custom")
        case .local: de("Lokal", en: "Local")
        }
    }

    /// Every provider but the one on this computer wants a key.
    public var needsKey: Bool { self != .local }

    /// nil for a custom endpoint, where the user supplies it, and for
    /// Microsoft, whose host depends on the region of the user's Speech
    /// resource (`MicrosoftSpeech.baseURL`).
    public var baseURL: URL? {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        case .groq: URL(string: "https://api.groq.com/openai/v1")
        case .google: URL(string: "https://generativelanguage.googleapis.com/v1beta")
        case .microsoft, .custom, .local: nil
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
        // The same model as above, straight from Microsoft.
        case .microsoft: MicrosoftSpeech.mai2
        case .google: GeminiTranscribe.model
        case .custom: ""
        // Whisper rather than Apple's: it hears German and English in one
        // recording, and takes the word list.
        case .local: ModelCatalog.whisperTurbo
        }
    }

    /// What a key from this provider looks like, shown as the field's placeholder.
    public var keyPlaceholder: String {
        switch self {
        case .openAI: "sk-…"
        case .openRouter: "sk-or-…"
        case .groq: "gsk_…"
        // Azure's keys are 32 hex characters with nothing to recognise them by.
        case .microsoft: de("Speech-Schlüssel", en: "Speech key")
        case .google: "AIza…"
        case .custom: de("API-Schlüssel", en: "API key")
        case .local: ""
        }
    }

    /// Where to create a key, for the setup's "Schlüssel holen".
    public var keyPage: URL? {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .microsoft: URL(string: "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices")
        case .google: URL(string: "https://aistudio.google.com/apikey")
        case .custom, .local: nil
        }
    }

    /// One sentence under the key for the two providers whose key is not
    /// obvious to get or has a catch.
    public var keyNote: String? {
        switch self {
        case .microsoft:
            de("Der Schlüssel einer Azure-Speech-Ressource (Standard S0). Er gilt nur in der Region der Ressource.",
               en: "The key of an Azure Speech resource (Standard S0). It only works in the resource's region.")
        case .google:
            de("Ein Gemini-Schlüssel aus Google AI Studio. Mit einem kostenlosen Schlüssel darf Google das Audio zur Verbesserung seiner Produkte nutzen, mit eingeschalteter Abrechnung nicht.",
               en: "A Gemini key from Google AI Studio. With a free key Google may use the audio to improve its products; with billing switched on it may not.")
        default: nil
        }
    }

    /// Whether "Füllwörter weglassen" does anything for this model. Only
    /// MAI-Transcribe 2 has a clean style (1.5 refused the whole request with
    /// it), and Gemini's transcribe models a smart mode.
    public func hasFillerSwitch(model: String) -> Bool {
        let id = model.lowercased()
        switch self {
        case .openRouter, .microsoft: return id.contains("mai-transcribe-2")
        case .google: return id.contains("transcribe")
        default: return false
        }
    }

    /// Each provider keeps its own key, so switching back and forth does not
    /// mean pasting keys again. The OpenAI account name predates providers and
    /// is kept so an existing key is still found.
    public var keychainAccount: String { rawValue }
}
