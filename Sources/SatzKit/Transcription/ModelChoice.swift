import Foundation

/// A transcription model in the settings' menu.
public struct ModelChoice: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let maker: String
    /// What an hour of speech costs, in dollars: measured by satz where it
    /// could, otherwise read from the provider's price list. nil if unknown.
    public let dollarsPerHour: Double?
    /// Artificial Analysis' word error rate (AA-WER) in percent: one score on
    /// the same ~8 hours of speech for every model, lower is better. nil where
    /// they have not measured this model.
    public let errorRate: Double?

    public init(_ id: String, _ name: String, _ maker: String, _ dollarsPerHour: Double? = nil, errorRate: Double? = nil) {
        self.id = id
        self.name = name
        self.maker = maker
        self.dollarsPerHour = dollarsPerHour
        self.errorRate = errorRate
    }
}

extension Provider {
    /// The list satz ships with: shown before the provider's own list has
    /// been fetched, and whenever it cannot be. The default first.
    public var models: [ModelChoice] {
        let ids: [String] = switch self {
        case .openRouter: [
            "microsoft/mai-transcribe-2", "microsoft/mai-transcribe-1.5", "openai/gpt-transcribe", "openai/gpt-4o-transcribe",
            "openai/gpt-4o-mini-transcribe", "openai/whisper-1", "openai/whisper-large-v3", "openai/whisper-large-v3-turbo",
            "assemblyai/universal-3-5-pro", "mistralai/voxtral-mini-transcribe", "mistralai/voxtral-small-24b-2507-stt",
            "mistralai/voxtral-mini-3b-2507", "qwen/qwen3-asr-flash-2026-02-10", "qwen/qwen3-asr-1.7b", "qwen/qwen3-asr-0.6b",
            "x-ai/grok-stt-1.0", "google/chirp-3", "fish-audio/transcribe-1",
        ]
        case .openAI: ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
        case .groq: ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .custom: []
        case .local: ModelCatalog.localModels
        }
        return ModelCatalog.sorted(ids.map { ModelCatalog.describe($0, for: self) }, default: defaultModel)
    }

    /// The menu's entry for a model id, nil for one typed in by hand.
    public func choice(for id: String, in list: [ModelChoice]? = nil) -> ModelChoice? {
        (list ?? models).first { $0.id == id }
    }
}

/// Which transcription models a provider has now, and what satz knows about
/// each: the price per hour of speech and how many words it gets wrong.
///
/// The list itself comes from the provider (OpenRouter without a key, OpenAI
/// and Groq with one), so new models show up without a new satz. What is
/// known about them comes from here, as of 07.10.2026.
public enum ModelCatalog {

    struct Known {
        var name: String?
        var maker: String?
        /// Billed by OpenRouter for satz's German and English test clips.
        var measured: Double?
        /// AA-WER from artificialanalysis.ai/speech-to-text, only where they
        /// measured this same model (and, where it matters, the same host).
        var errorRate: Double?
        /// Why it is left out of the menu, for a model that fails with satz.
        var hidden: String?
    }

    static let known: [String: Known] = [
        // OpenRouter, each sent a German and an English clip with satz's request.
        "microsoft/mai-transcribe-2": Known(name: "MAI-Transcribe 2", maker: "Microsoft", measured: 0.10, errorRate: 2.0),
        "microsoft/mai-transcribe-1.5": Known(name: "MAI-Transcribe 1.5", maker: "Microsoft", measured: 0.36, errorRate: 2.4),
        "openai/gpt-transcribe": Known(name: "GPT Transcribe", maker: "OpenAI", measured: 0.28, errorRate: 3.3),
        "openai/gpt-4o-transcribe": Known(name: "GPT-4o Transcribe", maker: "OpenAI", measured: 0.23, errorRate: 4.0),
        "openai/gpt-4o-mini-transcribe": Known(name: "GPT-4o mini Transcribe", maker: "OpenAI", measured: 0.12, errorRate: 4.5),
        // whisper-1 is Whisper Large v2, which AA measured at OpenAI.
        "openai/whisper-1": Known(name: "Whisper", maker: "OpenAI", measured: 0.37, errorRate: 4.1),
        "openai/whisper-large-v3": Known(name: "Whisper Large v3", maker: "OpenAI", measured: 0.03),
        // AA measured it at Groq, one of the hosts OpenRouter uses.
        "openai/whisper-large-v3-turbo": Known(name: "Whisper Large v3 Turbo", maker: "OpenAI", measured: 0.01, errorRate: 4.6),
        "assemblyai/universal-3-5-pro": Known(name: "Universal-3.5 Pro", maker: "AssemblyAI", measured: 0.44),
        "mistralai/voxtral-mini-transcribe": Known(name: "Voxtral Mini Transcribe", maker: "Mistral", measured: 0.15),
        "mistralai/voxtral-small-24b-2507-stt": Known(name: "Voxtral Small", maker: "Mistral", measured: 0.18, errorRate: 2.8),
        "mistralai/voxtral-mini-3b-2507": Known(name: "Voxtral Mini 3B", maker: "Mistral", measured: 0.06, errorRate: 3.8),
        "qwen/qwen3-asr-flash-2026-02-10": Known(name: "Qwen3 ASR Flash", maker: "Qwen", measured: 0.11),
        "qwen/qwen3-asr-1.7b": Known(name: "Qwen3 ASR 1.7B", maker: "Qwen", measured: 0.03),
        "qwen/qwen3-asr-0.6b": Known(name: "Qwen3 ASR 0.6B", maker: "Qwen", measured: 0.01),
        "x-ai/grok-stt-1.0": Known(name: "Grok STT", maker: "xAI", measured: 0.10, errorRate: 4.0),
        "google/chirp-3": Known(name: "Chirp 3", maker: "Google", measured: 1.00, errorRate: 4.3),
        "fish-audio/transcribe-1": Known(name: "Transcribe 1", maker: "Fish Audio", measured: 0.37),
        "google/gemini-3.5-transcribe": Known(hidden: "the provider refuses the request, even with nothing but the audio"),
        "meta/muse-voice-transcribe-1.0": Known(hidden: "needs an age check on the OpenRouter account"),
        "deepgram/nova-3": Known(hidden: "returns no text for German"),
        "fish-audio/transcribe-1-pro": Known(hidden: "puts speaker tags into the text"),
        "nvidia/parakeet-tdt-0.6b-v3": Known(hidden: "split German compounds wrongly in the test"),
        "nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b": Known(hidden: "split German compounds wrongly in the test"),
        // OpenAI directly.
        "gpt-transcribe": Known(name: "GPT Transcribe", maker: "OpenAI", errorRate: 3.3),
        "gpt-4o-transcribe": Known(name: "GPT-4o Transcribe", maker: "OpenAI", errorRate: 4.0),
        "gpt-4o-mini-transcribe": Known(name: "GPT-4o mini Transcribe", maker: "OpenAI", errorRate: 4.5),
        "whisper-1": Known(name: "Whisper", maker: "OpenAI", errorRate: 4.1),
        // Groq directly.
        "whisper-large-v3-turbo": Known(name: "Whisper Large v3 Turbo", maker: "OpenAI", errorRate: 4.6),
        "whisper-large-v3": Known(name: "Whisper Large v3", maker: "OpenAI"),
    ]

    // MARK: - On this computer

    /// Apple's speech recognition, built into macOS 26.
    public static let apple = "apple"
    /// Whisper Large v3 Turbo for WhisperKit, compressed to 632 MB for the
    /// Neural Engine. The id is WhisperKit's name for it, so any other
    /// WhisperKit model can be typed in under "Other model".
    public static let whisperTurbo = "openai_whisper-large-v3-v20240930_turbo_632MB"

    /// What runs on this Mac: Apple's only where macOS has it.
    static var localModels: [String] {
        if #available(macOS 26, *) { return [whisperTurbo, apple] }
        return [whisperTurbo]
    }

    /// Free to run; no error rate, because AA measured neither these builds.
    static var localKnown: [String: Known] {
        [
            apple: Known(name: de("Spracherkennung", en: "Speech recognition"), maker: "Apple", measured: 0),
            whisperTurbo: Known(name: "Whisper Large v3 Turbo", maker: "OpenAI", measured: 0),
        ]
    }

    /// "632 MB" from a WhisperKit name ending in "_632MB"; nil for Apple's
    /// and for a name without a size.
    public static func downloadSize(of id: String) -> String? {
        guard let last = id.split(separator: "_").last, last.hasSuffix("MB"), Int(last.dropLast(2)) != nil else { return nil }
        return "\(last.dropLast(2)) MB"
    }

    /// Where each provider lists its models. OpenRouter's list is public.
    static func listURL(for provider: Provider) -> URL? {
        switch provider {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/models?output_modalities=transcription")
        case .openAI: URL(string: "https://api.openai.com/v1/models")
        case .groq: URL(string: "https://api.groq.com/openai/v1/models")
        case .custom, .local: nil
        }
    }

    /// The provider's models now, best first. Throws when it cannot be asked;
    /// the caller then keeps the list it had.
    public static func fetch(_ provider: Provider, key: String?, session: URLSession = .shared) async throws -> [ModelChoice] {
        guard let url = listURL(for: provider) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if provider != .openRouter {
            guard let key, !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let list = try parse(data, for: provider)
        guard !list.isEmpty else { throw URLError(.zeroByteResource) }
        return list
    }

    /// `{"data": [{"id", "name"?, "pricing"?}]}`: OpenRouter's shape, and
    /// OpenAI's and Groq's, which list every model they have.
    static func parse(_ data: Data, for provider: Provider) throws -> [ModelChoice] {
        /// A price as listed: usually a string, sometimes a number or something
        /// else, which made the whole list fail to decode.
        struct Price: Decodable {
            let text: String?
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let string = try? value.decode(String.self) { text = string }
                else if let number = try? value.decode(Double.self) { text = String(number) }
                else { text = nil }
            }
        }
        struct Listing: Decodable {
            struct Model: Decodable {
                let id: String
                let name: String?
                let pricing: [String: Price]?
            }
            let data: [Model]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let models = listing.data.compactMap { model -> ModelChoice? in
            if provider != .openRouter {
                // Their lists hold every model; these are the ones that transcribe.
                let id = model.id.lowercased()
                guard id.contains("transcribe") || id.contains("whisper") else { return nil }
                // Realtime and diarizing variants need other endpoints.
                guard !id.contains("realtime"), !id.contains("diarize") else { return nil }
            }
            guard known[model.id]?.hidden == nil else { return nil }
            return describe(model.id, for: provider, listedName: model.name, pricing: model.pricing?.compactMapValues(\.text))
        }
        return sorted(models, default: provider.defaultModel)
    }

    /// What satz knows about a model id, filled in from the provider's listing.
    static func describe(_ id: String, for provider: Provider, listedName: String? = nil, pricing: [String: String]? = nil) -> ModelChoice {
        let entry = provider == .local ? localKnown[id] : known[id]
        // OpenRouter names its models "Maker: Name".
        let parts = listedName?.components(separatedBy: ": ")
        let maker = entry?.maker ?? (parts.flatMap { $0.count > 1 ? $0[0] : nil }) ?? id.components(separatedBy: "/").first ?? provider.name
        let name = entry?.name ?? parts?.last ?? id
        return ModelChoice(id, name, maker, entry?.measured ?? listedPrice(pricing), errorRate: entry?.errorRate)
    }

    /// OpenRouter's list gives a price without a unit. For speech models priced
    /// on the audio alone it is per hour when 0.01 or more and per second below
    /// that, which matches every model satz measured. A price per token (where
    /// a completion price is listed too) cannot become a price per hour here.
    static func listedPrice(_ pricing: [String: String]?) -> Double? {
        guard let pricing, let prompt = pricing["prompt"].flatMap(Double.init), prompt > 0 else { return nil }
        if let completion = pricing["completion"].flatMap(Double.init), completion > 0 { return nil }
        return prompt >= 0.01 ? prompt : prompt * 3600
    }

    /// The default first, then the fewest errors, then the cheapest; models
    /// without a score after those with one.
    static func sorted(_ models: [ModelChoice], default id: String) -> [ModelChoice] {
        models.sorted { a, b in
            if (a.id == id) != (b.id == id) { return a.id == id }
            switch (a.errorRate, b.errorRate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.dollarsPerHour ?? .infinity, a.name) < (b.dollarsPerHour ?? .infinity, b.name)
            }
        }
    }
}
