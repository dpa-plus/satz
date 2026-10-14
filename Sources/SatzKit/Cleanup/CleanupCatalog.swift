import Foundation

/// A JSON value for the fields a request carries beyond the common ones.
public indirect enum JSONValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])

    /// For `JSONSerialization`.
    var any: Any {
        switch self {
        case .string(let value): value
        // Whole numbers as integers: `"thinkingBudget": 0`, not `0.0`.
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
        case .bool(let value): value
        case .object(let fields): fields.mapValues(\.any)
        case .array(let items): items.map(\.any)
        }
    }
}

/// A cleanup model in the settings' menu, with what was measured about it.
public struct CleanupModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let maker: String
    /// Dollars per million tokens in and out; nil where unknown, 0 for free.
    public let input: Double?
    public let output: Double?
    /// Seconds for a typical dictation (about 60 words, 80 tokens out),
    /// measured from Munich through OpenRouter on 14.10.2026, ±50 %.
    public let seconds: Double?
    /// Tokens out per second, to scale `seconds` to other lengths.
    public let tokensPerSecond: Double?
    /// How many more tokens the model's tokenizer counts than the others for
    /// the same text: Claude's 1.7 (`CleanupCatalog.claudeTokens`), else 1.
    public let tokenFactor: Double
    let noteGerman: String?
    let noteEnglish: String?
    /// Body fields beyond the common ones: thinking switched off, mostly.
    public let extras: [String: JSONValue]
    /// OpenRouter's `reasoning` when its live list is not there (4.1).
    public let reasoning: JSONValue?
    /// The model refuses `temperature` (OpenAI's GPT-6, Azure).
    public let noTemperature: Bool

    public init(_ id: String, _ name: String, _ maker: String, input: Double? = nil, output: Double? = nil, seconds: Double? = nil,
                tokensPerSecond: Double? = nil, tokenFactor: Double = 1, note: (de: String, en: String)? = nil,
                extras: [String: JSONValue] = [:], reasoning: JSONValue? = nil, noTemperature: Bool = false) {
        self.id = id
        self.name = name
        self.maker = maker
        self.input = input
        self.output = output
        self.seconds = seconds
        self.tokensPerSecond = tokensPerSecond
        self.tokenFactor = tokenFactor
        noteGerman = note?.de
        noteEnglish = note?.en
        self.extras = extras
        self.reasoning = reasoning
        self.noTemperature = noTemperature
    }

    public func note(in language: Language = .current) -> String? {
        language == .english ? noteEnglish : noteGerman
    }

    /// Free to run: on this computer.
    public var isFree: Bool { input == 0 && output == 0 }

    /// The same model at another price, from OpenRouter's live list.
    func priced(input: Double?, output: Double?) -> CleanupModel {
        CleanupModel(id, name, maker, input: input ?? self.input, output: output ?? self.output, seconds: seconds,
                     tokensPerSecond: tokensPerSecond, tokenFactor: tokenFactor,
                     note: noteGerman.map { ($0, noteEnglish ?? $0) }, extras: extras, reasoning: reasoning, noTemperature: noTemperature)
    }
}

/// Which models each cleanup provider offers in the menu, and what satz knows
/// about them, as of 14.10.2026: each maker's current generation only (Eli:
/// "we should provide the latest models"). Only OpenRouter was called with a
/// real key; the direct providers' extras are as their documentation says,
/// untested, which is why each extra is dropped and the request sent once
/// more when a provider names it in a 400 (`CleanupRequest.retried`).
///
/// Left out on purpose (like `hidden` in `ModelCatalog`): older generations a
/// listed model replaces (Gemini 2.5 Flash-Lite, GPT-5.x, Grok 4.3 and older,
/// Mistral Small 3, Qwen3.7, GLM-5.2 and older); `qwen/qwen3.8-max-0902`
/// (thinks for 3.5 s and once appended "Wait, I need…");
/// `cohere/command-a-plus` (writes its reasoning into the answer, every
/// time); `liquid/lfm-2.5-24b-a2b` (empty answers);
/// `mistralai/ministral-8b-2512` (told the joke, Markdown, "um drei" became
/// "15 Uhr"); `nvidia/nemotron-3.5-lightning` (told jokes, translated);
/// `meta-llama/llama-4-maverick` (garbled); `inception/mercury-2.5` (empty
/// answers, translated); `openai/gpt-5.4-nano` (translated English phrases).
public enum CleanupCatalog {

    /// Apple's one model.
    public static let appleModel = "apple"

    private static let rewritesBest = (de: "Schreibt am besten um, gut für „Glatt“ und „Ausformuliert“.",
                                       en: "Rewrites best, good for “Smooth” and “Polished”.")
    private static let bestQuality = (de: "Beste Qualität.", en: "Best quality.")
    private static let fastest = (de: "Am schnellsten.", en: "The fastest.")
    private static let thinksBriefly = (de: "Denkt kurz nach.", en: "Thinks briefly.")
    private static let alwaysThinks = (de: "Denkt immer nach: mehrere Sekunden pro Diktat.", en: "Always thinks: several seconds per dictation.")
    /// Every model at Google, typed ones too: the key decides, not the model.
    private static let googleKey = (de: "Mit einem kostenlosen Schlüssel darf Google den Text zur Verbesserung seiner Produkte nutzen, mit eingeschalteter Abrechnung nicht.",
                                    en: "With a free key Google may use the text to improve its products; with billing switched on it may not.")
    private static func withGoogleKey(_ note: (de: String, en: String)) -> (de: String, en: String) {
        (note.de + " " + googleKey.de, note.en + " " + googleKey.en)
    }
    /// Ollama's and LM Studio's.
    public static let onThisComputer = (de: "Läuft auf diesem Computer, kostenlos. Kleine Modelle beantworten manchmal Fragen im Text; satz fügt dann das Original ein.",
                                        en: "Runs on this computer, free. Small models sometimes answer questions in the text; satz then pastes the original.")

    /// Claude's tokenizer counts about 1.5 times the input and twice the
    /// output tokens of the others for the same text (805 against 535 in,
    /// 174 against 85 out).
    static let claudeTokens = 1.7

    private static let thinkingOff: JSONValue = .object(["enabled": .bool(false)])
    private static func effort(_ value: String) -> JSONValue { .object(["effort": .string(value)]) }

    /// Through OpenRouter, the default first. `reasoning` is what the rule of
    /// `reasoning(for:listing:)` gave on 14.10. with the live list, for when
    /// the list cannot be fetched. All 17 were run through 14 tricky
    /// dictations at "Leicht" and "Ausformuliert": none answered, followed or
    /// translated.
    static let openRouter: [CleanupModel] = [
        CleanupModel("google/gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", "Google", input: 0.30, output: 2.50, seconds: 0.8,
                     tokensPerSecond: 250, note: (de: "Schnell. Schreibt bei „Ausformuliert“ wenig um.", en: "Fast. Rewrites little at “Polished”."),
                     reasoning: effort("minimal")),
        CleanupModel("qwen/qwen3.8-27b", "Qwen3.8 27B", "Qwen", input: 0.04, output: 2.30, seconds: 0.6,
                     tokensPerSecond: 300, note: fastest, reasoning: thinkingOff),
        CleanupModel("deepseek/deepseek-v4.1-flash", "DeepSeek V4.1 Flash", "DeepSeek", input: 0.021, output: 0.891, seconds: 0.8,
                     tokensPerSecond: 190, reasoning: thinkingOff),
        CleanupModel("anthropic/claude-haiku-5.5", "Claude Haiku 5.5", "Anthropic", input: 0.10, output: 0.50, seconds: 1.6,
                     tokensPerSecond: 165, tokenFactor: claudeTokens, note: rewritesBest, reasoning: thinkingOff),
        CleanupModel("openai/gpt-6-luna", "GPT-6 Luna", "OpenAI", input: 0.10, output: 0.50, seconds: 1.5,
                     tokensPerSecond: 112, reasoning: effort("none")),
        CleanupModel("z-ai/glm-5.3", "GLM-5.3", "Z.ai", input: 0.079, output: 4.80, seconds: 0.9,
                     tokensPerSecond: 100, reasoning: effort("low")),
        CleanupModel("minimax/minimax-m3", "MiniMax M3", "MiniMax", input: 0.30, output: 1.20, seconds: 1.4,
                     tokensPerSecond: 100, reasoning: thinkingOff),
        CleanupModel("mistralai/mistral-large-4-0", "Mistral Large 4", "Mistral", input: 0.68, output: 2.09, seconds: 1.7,
                     tokensPerSecond: 100, reasoning: effort("none")),
        CleanupModel("google/gemini-3.8-flash", "Gemini 3.8 Flash", "Google", input: 0.75, output: 3.75, seconds: 1.4,
                     tokensPerSecond: 145, reasoning: effort("low")),
        CleanupModel("moonshotai/kimi-k3", "Kimi K3", "Moonshot AI", input: 0.62, output: 15.00, seconds: 1.4,
                     tokensPerSecond: 100, reasoning: thinkingOff),
        CleanupModel("deepseek/deepseek-v4-pro-0813", "DeepSeek V4 Pro", "DeepSeek", input: 1.32, output: 3.96, seconds: 1.2,
                     tokensPerSecond: 100, reasoning: thinkingOff),
        CleanupModel("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5", "Anthropic", input: 2.00, output: 10.00, seconds: 1.4,
                     tokensPerSecond: 100, tokenFactor: claudeTokens, note: bestQuality, reasoning: effort("low")),
        CleanupModel("openai/gpt-6-sol", "GPT-6 Sol", "OpenAI", input: 2.00, output: 10.00, seconds: 1.4,
                     tokensPerSecond: 100, reasoning: effort("none")),
        CleanupModel("openai/gpt-6.1-sol", "GPT-6.1 Sol", "OpenAI", input: 2.00, output: 10.00, seconds: 2.1,
                     tokensPerSecond: 50, note: thinksBriefly, reasoning: effort("low")),
        CleanupModel("google/gemini-4-argon", "Gemini 4 Argon", "Google", input: 2.00, output: 10.00, seconds: 2.3,
                     tokensPerSecond: 100, note: thinksBriefly, reasoning: effort("low")),
        CleanupModel("anthropic/claude-opus-5.5", "Claude Opus 5.5", "Anthropic", input: 4.00, output: 20.00, seconds: 2.7,
                     tokensPerSecond: 80, tokenFactor: claudeTokens, note: thinksBriefly, reasoning: effort("low")),
        CleanupModel("x-ai/grok-4.7", "Grok 4.7", "xAI", input: 2.00, output: 6.00, seconds: 4.6,
                     tokensPerSecond: 65, note: alwaysThinks, reasoning: effort("low")),
    ]

    private static let gptExtras: [String: JSONValue] = ["reasoning_effort": .string("none")]
    private static let haikuExtras: [String: JSONValue] = ["thinking": .object(["type": .string("disabled")])]
    /// Sonnet's and Opus's thinking cannot be switched off, only kept short.
    private static let claudeThinksLittle: [String: JSONValue] = ["output_config": .object(["effort": .string("low")])]
    private static let ossExtras: [String: JSONValue] = ["reasoning_effort": .string("low"), "include_reasoning": .bool(false)]
    private static let noReasoning: [String: JSONValue] = ["reasoning_effort": .string("none")]
    /// DeepSeek refuses `reasoning_effort: "none"`.
    private static let deepSeekExtras: [String: JSONValue] = ["thinking": .object(["type": .string("disabled")])]
    private static func geminiThinking(_ level: String) -> [String: JSONValue] {
        ["thinkingConfig": .object(["thinkingLevel": .string(level)])]
    }

    /// The models each provider's menu offers, the default first.
    public static func models(for provider: CleanupProvider) -> [CleanupModel] {
        switch provider {
        case .openRouter:
            return openRouter
        case .openAI:
            return [
                CleanupModel("gpt-6-luna", "GPT-6 Luna", "OpenAI", input: 0.10, output: 0.50, seconds: 1.5, tokensPerSecond: 112,
                             extras: gptExtras, noTemperature: true),
                CleanupModel("gpt-6-sol", "GPT-6 Sol", "OpenAI", input: 2.00, output: 10.00, seconds: 1.4, tokensPerSecond: 100,
                             extras: gptExtras, noTemperature: true),
                // It cannot stop thinking.
                CleanupModel("gpt-6.1-sol", "GPT-6.1 Sol", "OpenAI", input: 2.00, output: 10.00, seconds: 2.1, tokensPerSecond: 50,
                             note: thinksBriefly, extras: ["reasoning_effort": .string("low")], noTemperature: true),
            ]
        case .anthropic:
            // No sampling parameters at all: Claude 5.5 models refuse them.
            return [
                CleanupModel("claude-haiku-5-5", "Claude Haiku 5.5", "Anthropic", input: 0.10, output: 0.50, seconds: 1.6,
                             tokensPerSecond: 165, tokenFactor: claudeTokens, extras: haikuExtras, noTemperature: true),
                CleanupModel("claude-sonnet-5-5", "Claude Sonnet 5.5", "Anthropic", input: 2.00, output: 10.00, seconds: 1.4,
                             tokensPerSecond: 100, tokenFactor: claudeTokens, note: bestQuality, extras: claudeThinksLittle, noTemperature: true),
                CleanupModel("claude-opus-5-5", "Claude Opus 5.5", "Anthropic", input: 4.00, output: 20.00, seconds: 2.7,
                             tokensPerSecond: 80, tokenFactor: claudeTokens, extras: claudeThinksLittle, noTemperature: true),
            ]
        case .google:
            return [
                CleanupModel("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", "Google", input: 0.30, output: 2.50, seconds: 0.8,
                             tokensPerSecond: 250, note: googleKey, extras: geminiThinking("minimal")),
                CleanupModel("gemini-3.8-flash", "Gemini 3.8 Flash", "Google", input: 0.75, output: 3.75, seconds: 1.4,
                             tokensPerSecond: 145, note: withGoogleKey((de: "Ab 2027 doppelt so teuer.", en: "Twice the price from 2027.")),
                             extras: geminiThinking("low")),
                CleanupModel("gemini-4-argon", "Gemini 4 Argon", "Google", input: 2.00, output: 10.00, seconds: 2.3,
                             tokensPerSecond: 100, note: withGoogleKey(thinksBriefly), extras: geminiThinking("low")),
            ]
        case .groq:
            return [
                CleanupModel("openai/gpt-oss-120b", "gpt-oss-120b", "OpenAI", input: 0.15, output: 0.60, seconds: 0.7, tokensPerSecond: 470,
                             note: thinksBriefly, extras: ossExtras),
                CleanupModel("qwen/qwen3.8-27b", "Qwen3.8 27B", "Qwen", input: 0.80, output: 4.00, seconds: 0.6, tokensPerSecond: 450,
                             note: (de: "Vorschau bei Groq.", en: "Preview at Groq."), extras: noReasoning),
                CleanupModel("openai/gpt-oss-20b", "gpt-oss-20b", "OpenAI", input: 0.075, output: 0.30, seconds: 0.6, tokensPerSecond: 950,
                             extras: ossExtras),
            ]
        case .cerebras:
            return [
                CleanupModel("qwen-3.8-27b", "Qwen3.8 27B", "Qwen", input: 0.99, output: 1.49, seconds: 0.5, tokensPerSecond: 1800,
                             note: fastest, extras: noReasoning),
                CleanupModel("gpt-oss-120b", "gpt-oss-120b", "OpenAI", input: 0.35, output: 0.75, seconds: 0.5, tokensPerSecond: 1500,
                             extras: ["reasoning_effort": .string("low"), "reasoning_format": .string("hidden")]),
            ]
        case .mistral:
            // "-latest" is Mistral's own alias for its newest model of each size.
            return [
                CleanupModel("mistral-small-latest", "Mistral Small", "Mistral", input: 0.15, output: 0.60, seconds: 0.9,
                             tokensPerSecond: 146, extras: noReasoning),
                CleanupModel("mistral-large-latest", "Mistral Large", "Mistral", input: 0.68, output: 2.09, seconds: 1.7,
                             tokensPerSecond: 100, extras: noReasoning),
                CleanupModel("mistral-medium-latest", "Mistral Medium", "Mistral", input: 1.50, output: 7.50, seconds: 2.2,
                             tokensPerSecond: 166, extras: noReasoning),
            ]
        case .deepseek:
            return [
                CleanupModel("deepseek-flash", "DeepSeek V4.1 Flash", "DeepSeek", input: 0.30, output: 1.20, seconds: 1.1, tokensPerSecond: 190,
                             note: (de: "Nachts (UTC) halb so teuer.", en: "Half price at night (UTC)."), extras: deepSeekExtras),
                CleanupModel("deepseek-v4-pro-0813", "DeepSeek V4 Pro", "DeepSeek", input: 1.32, output: 3.96, seconds: 1.5, tokensPerSecond: 100,
                             extras: deepSeekExtras),
            ]
        case .xai:
            // Its only model that cleans up well at all; the others told jokes.
            return [
                CleanupModel("grok-4.7", "Grok 4.7", "xAI", input: 2.00, output: 6.00, seconds: 4.6, tokensPerSecond: 65,
                             note: alwaysThinks, extras: ["reasoning_effort": .string("low")]),
            ]
        case .apple, .azure, .ollama, .lmStudio, .custom:
            return []
        }
    }

    /// What satz knows about a model id at a provider: the menu's entry, or
    /// one made up for an id typed by hand, an Azure deployment or a model
    /// installed in Ollama, with the extras its family needs. `listing` is
    /// OpenRouter's live entry for it, which wins on the price.
    public static func model(_ id: String, for provider: CleanupProvider, listing: OpenRouterListing? = nil) -> CleanupModel {
        let typed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = models(for: provider).first(where: { $0.id == typed }) {
            return listing.map { known.priced(input: $0.input, output: $0.output) } ?? known
        }
        switch provider {
        case .apple:
            return CleanupModel(appleModel, "Apple Intelligence", "Apple", input: 0, output: 0, noTemperature: true)
        case .openRouter:
            // Named by OpenRouter as "maker/model"; priced only by its list.
            let maker = typed.components(separatedBy: "/").first ?? "OpenRouter"
            return CleanupModel(typed, typed, maker, input: listing?.input, output: listing?.output,
                                tokenFactor: typed.hasPrefix("anthropic/") ? claudeTokens : 1)
        case .anthropic:
            // Any Claude model: its thinking off, no sampling parameters.
            return CleanupModel(typed, typed, "Anthropic", tokenFactor: claudeTokens, extras: haikuExtras, noTemperature: true)
        case .google:
            let thinking: JSONValue = typed.contains("2.5") ? .object(["thinkingBudget": .number(0)]) : .object(["thinkingLevel": .string("minimal")])
            return CleanupModel(typed, typed, "Google", note: googleKey, extras: ["thinkingConfig": thinking])
        case .azure:
            // A deployment of one of OpenAI's models costs what OpenAI's does.
            let openAI = models(for: .openAI).first { typed.lowercased().contains($0.id) }
            return CleanupModel(typed, typed, "Microsoft", input: openAI?.input, output: openAI?.output, seconds: 1.5,
                                tokensPerSecond: 100, noTemperature: true)
        case .ollama:
            return CleanupModel(typed, typed, "Ollama", input: 0, output: 0, extras: noReasoning)
        case .lmStudio:
            return CleanupModel(typed, typed, "LM Studio", input: 0, output: 0)
        default:
            return CleanupModel(typed, typed, provider.name)
        }
    }

    // MARK: - OpenRouter's live list

    /// OpenRouter's public list: its prices now, and whether a model's
    /// thinking can be switched off.
    public static let openRouterList = URL(string: "https://openrouter.ai/api/v1/models")!

    /// `data[]` with `pricing.prompt` / `pricing.completion` in dollars per
    /// token, as strings, and `reasoning` with `supported_efforts` and
    /// `mandatory` where the model thinks.
    public static func parseOpenRouter(_ data: Data) throws -> [String: OpenRouterListing] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var result: [String: OpenRouterListing] = [:]
        for entry in list {
            guard let id = entry["id"] as? String else { continue }
            let pricing = entry["pricing"] as? [String: Any]
            func perMillion(_ key: String) -> Double? {
                let value = pricing?[key]
                let number = (value as? String).flatMap(Double.init) ?? (value as? Double)
                // A negative price means "varies" (a router), not a refund.
                return number.flatMap { $0 >= 0 ? $0 * 1_000_000 : nil }
            }
            let reasoning = entry["reasoning"] as? [String: Any]
            result[id] = OpenRouterListing(id: id, input: perMillion("prompt"), output: perMillion("completion"),
                                           efforts: reasoning?["supported_efforts"] as? [String],
                                           mandatory: reasoning?["mandatory"] as? Bool)
        }
        guard !result.isEmpty else { throw URLError(.zeroByteResource) }
        return result
    }

    /// How OpenRouter is told to keep the model from thinking (4.1): "none"
    /// where it can be asked for, switched off where it is not mandatory,
    /// else the least effort it takes. Without any list, the catalog's value
    /// (and for an id nobody knows, switched off). With a list (`listKept`),
    /// a model it lacks, or one it says nothing about thinking for, has no
    /// metadata: switched off, and once more at "low" if a 400 names reasoning
    /// (`CleanupRequest.retried`). The same rule on Windows and Linux.
    public static func reasoning(for model: CleanupModel, listing: OpenRouterListing?, listKept: Bool = false) -> JSONValue {
        guard let listing else { return listKept ? thinkingOff : (model.reasoning ?? thinkingOff) }
        guard listing.efforts != nil || listing.mandatory != nil else { return thinkingOff }
        let efforts = listing.efforts ?? []
        if efforts.contains("none") { return effort("none") }
        if listing.mandatory != true { return thinkingOff }
        let order = ["minimal", "low", "medium", "high", "xhigh", "max"]
        // Mandatory and no effort named: the one every model takes.
        return effort(order.first(where: { efforts.contains($0) }) ?? "low")
    }

    // MARK: - Ollama and LM Studio

    /// `GET {address}/models` in OpenAI's format (`data[].id`): what is
    /// installed or loaded. Embedding models are left out, they answer no
    /// chat. nil for an answer that is none of that.
    public static func installedModels(in data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }.filter { !$0.lowercased().contains("embed") }
    }
}

/// One model in OpenRouter's live list.
public struct OpenRouterListing: Codable, Hashable, Sendable {
    public let id: String
    /// Dollars per million tokens.
    public let input: Double?
    public let output: Double?
    public let efforts: [String]?
    public let mandatory: Bool?

    public init(id: String, input: Double?, output: Double?, efforts: [String]? = nil, mandatory: Bool? = nil) {
        self.id = id
        self.input = input
        self.output = output
        self.efforts = efforts
        self.mandatory = mandatory
    }
}
