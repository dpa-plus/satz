import Foundation

/// A transcription model in the settings' menu.
public struct ModelChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let maker: String
    /// What an hour of speech cost when it was tested, in dollars. nil where
    /// satz has not measured it.
    public let dollarsPerHour: Double?

    public init(_ id: String, _ name: String, _ maker: String, _ dollarsPerHour: Double? = nil) {
        self.id = id
        self.name = name
        self.maker = maker
        self.dollarsPerHour = dollarsPerHour
    }
}

extension Provider {
    /// The models offered in the menu, the default first. Anything else can
    /// still be typed in under "Other".
    ///
    /// The OpenRouter ones each passed a German and an English test dictation
    /// with satz's own request on 07.10.2026, and the prices are what
    /// OpenRouter billed for them then. Left out from its list: Gemini 3.5
    /// Transcribe and MAI-Transcribe 1.5 (the provider refused the request),
    /// Meta Muse (needs an age check on the account), Deepgram Nova-3 (no
    /// text for German), Fish Audio Pro (speaker tags in the text), and
    /// NVIDIA's Parakeet and Nemotron (split German compounds wrongly).
    public var models: [ModelChoice] {
        switch self {
        case .openRouter: [
            ModelChoice("microsoft/mai-transcribe-2", "MAI-Transcribe 2", "Microsoft", 0.10),
            ModelChoice("openai/gpt-transcribe", "GPT Transcribe", "OpenAI", 0.28),
            ModelChoice("openai/gpt-4o-transcribe", "GPT-4o Transcribe", "OpenAI", 0.23),
            ModelChoice("openai/gpt-4o-mini-transcribe", "GPT-4o mini Transcribe", "OpenAI", 0.12),
            ModelChoice("openai/whisper-1", "Whisper", "OpenAI", 0.37),
            ModelChoice("openai/whisper-large-v3", "Whisper Large v3", "OpenAI", 0.03),
            ModelChoice("openai/whisper-large-v3-turbo", "Whisper Large v3 Turbo", "OpenAI", 0.01),
            ModelChoice("assemblyai/universal-3-5-pro", "Universal-3.5 Pro", "AssemblyAI", 0.44),
            ModelChoice("mistralai/voxtral-mini-transcribe", "Voxtral Mini Transcribe", "Mistral", 0.15),
            ModelChoice("mistralai/voxtral-small-24b-2507-stt", "Voxtral Small", "Mistral", 0.18),
            ModelChoice("mistralai/voxtral-mini-3b-2507", "Voxtral Mini 3B", "Mistral", 0.06),
            ModelChoice("qwen/qwen3-asr-flash-2026-02-10", "Qwen3 ASR Flash", "Qwen", 0.11),
            ModelChoice("qwen/qwen3-asr-1.7b", "Qwen3 ASR 1.7B", "Qwen", 0.03),
            ModelChoice("qwen/qwen3-asr-0.6b", "Qwen3 ASR 0.6B", "Qwen", 0.01),
            ModelChoice("x-ai/grok-stt-1.0", "Grok STT", "xAI", 0.10),
            ModelChoice("google/chirp-3", "Chirp 3", "Google", 1.00),
            ModelChoice("fish-audio/transcribe-1", "Transcribe 1", "Fish Audio", 0.37),
        ]
        case .openAI: [
            ModelChoice("gpt-transcribe", "GPT Transcribe", "OpenAI"),
            ModelChoice("gpt-4o-transcribe", "GPT-4o Transcribe", "OpenAI"),
            ModelChoice("gpt-4o-mini-transcribe", "GPT-4o mini Transcribe", "OpenAI"),
            ModelChoice("whisper-1", "Whisper", "OpenAI"),
        ]
        case .groq: [
            ModelChoice("whisper-large-v3-turbo", "Whisper Large v3 Turbo", "OpenAI"),
            ModelChoice("whisper-large-v3", "Whisper Large v3", "OpenAI"),
        ]
        case .custom: []
        }
    }

    /// The menu's entry for a model id, nil for one typed in by hand.
    public func choice(for id: String) -> ModelChoice? {
        models.first { $0.id == id }
    }
}
