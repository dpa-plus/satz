import Foundation

/// Everything one cleanup needs, read from the settings at the moment it runs.
public struct CleanupJob: Sendable {
    public var provider: CleanupProvider
    public var model: CleanupModel
    /// The address as typed, for the providers that have one.
    public var address: String
    /// nil or empty: none is sent.
    public var key: String?
    public var level: CleanupLevel
    public var customPrompt: String
    /// The Wortschatz: the user's words, not the replacements' phrases.
    public var vocabulary: [String]
    /// OpenRouter's live entry for the model, for its thinking switch.
    public var listing: OpenRouterListing?
    /// OpenRouter's list is there (kept from an earlier fetch) but may not
    /// have this model. Without any list the catalog's thinking switch
    /// applies; with one, a model it lacks gets "off" (`CleanupCatalog.reasoning`).
    public var listKept: Bool
    /// Test mode: nothing goes to a provider that costs money, only to this
    /// computer (a stand-in server, Apple's model). Windows and Linux have
    /// the same switch (`onlyThisComputer`).
    public var onlyThisComputer: Bool

    public init(provider: CleanupProvider, model: CleanupModel, address: String = "", key: String? = nil, level: CleanupLevel,
                customPrompt: String = "", vocabulary: [String] = [], listing: OpenRouterListing? = nil,
                listKept: Bool = false, onlyThisComputer: Bool = false) {
        self.provider = provider
        self.model = model
        self.address = address
        self.key = key
        self.level = level
        self.customPrompt = customPrompt
        self.vocabulary = vocabulary
        self.listing = listing
        self.listKept = listKept || listing != nil
        self.onlyThisComputer = onlyThisComputer
    }

    /// What keeps it from running, before anything is sent. The order is the
    /// same on Windows and Linux: the prompt, Apple, the key, the address,
    /// the model.
    public var missing: CleanupFailure? {
        if level == .custom, customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noPrompt }
        if provider == .apple { return nil }
        if provider.needsKey, (key ?? "").isEmpty { return .noKey }
        if provider.hasAddress, baseURL == nil { return .noAddress }
        if model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noModel }
        return nil
    }

    /// Where the request goes, without the path of the call itself.
    public var baseURL: URL? {
        if let fixed = provider.fixedBase { return fixed }
        switch provider {
        case .azure: return CleanupAddress.azureOrigin(address).map { $0.appendingPathComponent("openai/v1") }
        case .ollama, .lmStudio, .custom: return CleanupAddress.url(provider.address(address))
        default: return nil
        }
    }

    /// On this computer: the first call loads the model.
    public var runsHere: Bool {
        provider.runsHere || baseURL.map(CleanupAddress.isThisComputer) == true
    }

    /// Whether the request stays on this computer: Apple's model, or an
    /// address that is this computer's. Ollama at a remote address does not.
    public var staysOnThisComputer: Bool {
        provider == .apple || baseURL.map(CleanupAddress.isThisComputer) == true
    }
}

/// Estimates that need no model: tokens from characters, the answer's
/// budget, how long to wait. The same numbers on Windows and Linux.
public enum CleanupTiming {

    /// Characters as Unicode scalars (code points), the way the other
    /// platform counts them: Swift's `count` counts what a reader sees as one
    /// (a flag, "e" and its accent), so an emoji and a decomposed letter
    /// would be one here and two or more there.
    public static func characters(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// About 4.5 characters a token, for German and English alike: satz's
    /// prompt for "Leicht" (1,764 characters) was billed as about 430 tokens,
    /// a 400-character German dictation as about 80. Claude counts more
    /// (`CleanupModel.tokenFactor`). The same count everywhere, as on Windows
    /// and Linux: the estimate, the answer's budget, the timeouts and what
    /// fits Apple's model.
    public static func tokens(_ characters: Double) -> Double {
        (characters / 4.5).rounded(.up)
    }

    public static func tokens(_ characters: Int) -> Int {
        Int(tokens(Double(characters)))
    }

    /// Room a model needs to think before it answers, when its thinking is not
    /// switched off all the way: "low" and "minimal" still spend tokens, and
    /// they come out of the same budget. An answer cut off by it was lost.
    static let thinkingRoom = 2000

    /// Room for an answer twice as long as the text, a margin, and the room
    /// to think where the request leaves the model thinking. Billing is per
    /// token generated, so a higher ceiling costs nothing by itself; the guard
    /// still rejects a runaway answer.
    public static func maxTokens(for text: String, thinkingRoom: Int = 0) -> Int {
        min(8000, 2 * tokens(characters(text)) + 200 + thinkingRoom)
    }

    /// What the answer is expected to be, in tokens: the text's, by the
    /// level's factor (fillers go at "Leicht" and "Glatt").
    public static func estimatedOutputTokens(for text: String, level: CleanupLevel) -> Double {
        Double(tokens(characters(text))) * level.outputFactor
    }

    /// Cloud: 6 s plus the time to write the answer at 40 tokens a second,
    /// at most 30 s. On this computer the first call loads the model: 20 s
    /// and 15 tokens a second, at most a minute. Never less than three times
    /// what the catalog measured for the model: Grok 4.7 always thinks, 4.6 s
    /// at the median and 6.5 s at the slowest, and the clock must not cut it off.
    public static func timeout(for text: String, level: CleanupLevel, runsHere: Bool, catalogSeconds: Double? = nil) -> TimeInterval {
        let out = estimatedOutputTokens(for: text, level: level)
        let rule = runsHere ? 20 + out / 15 : 6 + out / 40
        return min(runsHere ? 60 : 30, max(rule, 3 * (catalogSeconds ?? 0)))
    }
}

/// The request for each family, and what is read out of the answer.
public enum CleanupRequest {

    /// The body as fields, so a retry can take one out.
    public typealias Body = [String: JSONValue]

    public static func make(_ job: CleanupJob, text: String) -> (URLRequest, Body)? {
        guard let base = job.baseURL else { return nil }
        let messages = CleanupPrompt.messages(job.level, text: text, vocabulary: job.vocabulary, customPrompt: job.customPrompt)
        let body = body(job, messages: messages, text: text)
        return (request(job, base: base, body: body), body)
    }

    static func url(_ job: CleanupJob, base: URL) -> URL {
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        let path = switch job.provider.family {
        case .anthropic: "/messages"
        case .gemini: "/models/\(geminiID(job.model.id)):generateContent"
        case .openAI, .apple: "/chat/completions"
        }
        return URL(string: root + path) ?? base
    }

    /// What is allowed in a URL's path segment unescaped, as JavaScript's
    /// `encodeURIComponent` has it: the same URL on Windows and Linux.
    private static let unescaped = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// A Gemini model as the call's path wants it: Google lists models as
    /// "models/gemini-3.5-flash-lite", and the path has "models/" already.
    static func geminiID(_ id: String) -> String {
        let bare = id.hasPrefix("models/") ? String(id.dropFirst("models/".count)) : id
        return bare.addingPercentEncoding(withAllowedCharacters: unescaped) ?? bare
    }

    public static func request(_ job: CleanupJob, base: URL, body: Body) -> URLRequest {
        var request = URLRequest(url: url(job, base: base))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = (job.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            switch (job.provider.family, job.provider) {
            case (.anthropic, _):
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            case (.gemini, _):
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            case (_, .azure):
                request.setValue(key, forHTTPHeaderField: "api-key")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        if job.provider.family == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body.mapValues(\.any), options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    static func body(_ job: CleanupJob, messages: CleanupPrompt.Messages, text: String) -> Body {
        let model = job.model
        var body: Body
        switch job.provider.family {
        case .anthropic:
            body = [
                "model": .string(model.id),
                "system": .string(messages.system),
            ]
            body["messages"] = .array(messages.turns.map { .object(["role": .string($0.role.rawValue), "content": .string($0.content)]) })
            for (field, value) in model.extras { body[field] = value }
        case .gemini:
            var config: [String: JSONValue] = ["temperature": .number(0)]
            for (field, value) in model.extras { config[field] = value }
            body = [
                "systemInstruction": .object(["parts": .array([.object(["text": .string(messages.system)])])]),
                "contents": .array(messages.turns.map {
                    .object(["role": .string($0.role == .user ? "user" : "model"), "parts": .array([.object(["text": .string($0.content)])])])
                }),
                "generationConfig": .object(config),
            ]
        case .openAI, .apple:
            var turns: [JSONValue] = [.object(["role": .string("system"), "content": .string(messages.system)])]
            turns += messages.turns.map { .object(["role": .string($0.role.rawValue), "content": .string($0.content)]) }
            body = ["model": .string(model.id), "messages": .array(turns), "stream": .bool(false)]
            if !model.noTemperature { body["temperature"] = .number(0) }
            for (field, value) in model.extras { body[field] = value }
            if job.provider == .openRouter {
                body["reasoning"] = CleanupCatalog.reasoning(for: model, listing: job.listing, listKept: job.listKept)
                // The answer then says what it cost, in dollars.
                body["usage"] = .object(["include": .bool(true)])
                body["provider"] = .object(["sort": .string("latency")])
            }
        }
        setBudget(&body, job: job, text: text)
        return body
    }

    // MARK: - The answer's budget

    /// The field that limits the answer's length, in each family's name.
    /// OpenAI's newer models and Azure take only the newer one.
    private static func budgetField(_ job: CleanupJob) -> String {
        switch job.provider.family {
        case .anthropic: "max_tokens"
        case .gemini: "maxOutputTokens"
        case .openAI, .apple: job.provider == .openAI || job.provider == .azure ? "max_completion_tokens" : "max_tokens"
        }
    }

    /// Sets the answer's limit for the body as it is now: twice the text and a
    /// margin, plus room to think unless the body switches thinking off. Asked
    /// again after a retry, which may have taken the switch out.
    static func setBudget(_ body: inout Body, job: CleanupJob, text: String) {
        let room = switchesThinkingOff(body, family: job.provider.family) ? 0 : CleanupTiming.thinkingRoom
        let value = JSONValue.number(Double(CleanupTiming.maxTokens(for: text, thinkingRoom: room)))
        if job.provider.family == .gemini {
            guard case .object(var config)? = body["generationConfig"] else { return }
            config[budgetField(job)] = value
            body["generationConfig"] = .object(config)
        } else {
            body[budgetField(job)] = value
        }
    }

    /// Whether thinking is off all the way: OpenRouter's `{enabled: false}`
    /// or `{effort: "none"}`, `reasoning_effort: "none"`, a disabled
    /// `thinking` (Anthropic's, DeepSeek's), Gemini's `thinkingBudget: 0`.
    /// Anything less ("low", "minimal", Gemini's levels, Anthropic's
    /// `output_config`) and a model whose switch is not known still thinks.
    static func switchesThinkingOff(_ body: Body, family: CleanupProvider.Family) -> Bool {
        let disabled = JSONValue.object(["type": .string("disabled")])
        switch family {
        case .anthropic:
            return body["thinking"] == disabled
        case .gemini:
            guard case .object(let config)? = body["generationConfig"], case .object(let thinking)? = config["thinkingConfig"] else { return false }
            return thinking["thinkingBudget"] == .number(0)
        case .openAI, .apple:
            if let reasoning = body["reasoning"] {
                return reasoning == .object(["enabled": .bool(false)]) || reasoning == .object(["effort": .string("none")])
            }
            return body["reasoning_effort"] == .string("none") || body["thinking"] == disabled
        }
    }

    /// The body once more after a 400 that names one of the extra fields: a
    /// provider that changed its API still answers without it. nil when the
    /// message names none, or nothing would change.
    public static func retried(_ body: Body, job: CleanupJob, message: String, text: String) -> Body? {
        let said = message.lowercased()
        var body = body
        var changed = false
        if job.provider == .openRouter, said.contains("reasoning"), let sent = body["reasoning"] {
            // "Off" refused: maybe it must think. Any other value refused: without.
            if sent == .object(["enabled": .bool(false)]) {
                body["reasoning"] = .object(["effort": .string("low")])
            } else {
                body["reasoning"] = nil
            }
            changed = true
        }
        if job.provider.family == .gemini, said.contains("thinking"), case .object(var config)? = body["generationConfig"],
           config["thinkingConfig"] != nil {
            config["thinkingConfig"] = nil
            body["generationConfig"] = .object(config)
            changed = true
        }
        for field in job.model.extras.keys where body[field] != nil && said.contains(field.lowercased()) {
            body[field] = nil
            changed = true
        }
        // A model typed by hand that takes no temperature.
        if body["temperature"] != nil, said.contains("temperature") {
            body["temperature"] = nil
            changed = true
        }
        guard changed else { return nil }
        // A model that now thinks (or may) needs the room for it.
        setBudget(&body, job: job, text: text)
        return body
    }

    // MARK: - The answer

    public struct Answer: Equatable, Sendable {
        public var text: String?
        public var refused = false
        /// It stopped at `max_tokens`: thinking models spend the same budget
        /// on their thinking, and what is missing is the end of the dictation.
        public var truncated = false
        public var inputTokens: Int?
        public var outputTokens: Int?
        /// OpenRouter's `usage.cost`, in dollars.
        public var cost: Double?
    }

    /// The finishReasons with which Gemini holds an answer back instead of
    /// finishing it: filters, a block list, personal data, a quote. The same
    /// five on Windows and Linux (`geminiBlocks`).
    static let geminiBlocks: Set<String> = ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION"]

    public static func parse(_ data: Data, family: CleanupProvider.Family) -> Answer? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var answer = Answer()
        switch family {
        case .anthropic:
            let parts = object["content"] as? [[String: Any]] ?? []
            answer.text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            answer.refused = object["stop_reason"] as? String == "refusal"
            answer.truncated = object["stop_reason"] as? String == "max_tokens"
            let usage = object["usage"] as? [String: Any]
            answer.inputTokens = usage?["input_tokens"] as? Int
            answer.outputTokens = usage?["output_tokens"] as? Int
        case .gemini:
            let usage = object["usageMetadata"] as? [String: Any]
            answer.inputTokens = usage?["promptTokenCount"] as? Int
            answer.outputTokens = usage?["candidatesTokenCount"] as? Int
            // A prompt Gemini will not answer comes back without any
            // candidate, the reason only in promptFeedback: a block, whatever
            // else the body holds (a JSON null is no reason). Windows and
            // Linux read it the same way (`parseAnswer`).
            if let reason = (object["promptFeedback"] as? [String: Any])?["blockReason"], !(reason is NSNull) {
                answer.text = ""
                answer.refused = true
                break
            }
            let candidate = (object["candidates"] as? [[String: Any]])?.first
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            // Parts marked as thought are the model thinking aloud.
            answer.text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            // A candidate that stopped for a block often carries some text:
            // what a filter let through before it stopped is no answer to paste.
            answer.refused = geminiBlocks.contains(candidate?["finishReason"] as? String ?? "")
            answer.truncated = candidate?["finishReason"] as? String == "MAX_TOKENS"
        case .openAI, .apple:
            let choice = (object["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            answer.truncated = choice?["finish_reason"] as? String == "length"
            if let text = message?["content"] as? String {
                answer.text = text
            } else if let parts = message?["content"] as? [[String: Any]] {
                answer.text = parts.compactMap { $0["text"] as? String }.joined()
            }
            if let refusal = message?["refusal"] as? String, !refusal.isEmpty { answer.refused = true }
            let usage = object["usage"] as? [String: Any]
            answer.inputTokens = usage?["prompt_tokens"] as? Int
            answer.outputTokens = usage?["completion_tokens"] as? Int
            answer.cost = (usage?["cost"] as? Double) ?? (usage?["cost"] as? Int).map(Double.init)
        }
        return answer
    }

    /// `{"error": {"message": …}}`, Anthropic's and Google's too, or a bare
    /// `{"message": …}`; the first 200 characters. Only to read: the retry
    /// looks in it for the extra field the provider refuses. It is never
    /// logged, because a provider may quote the request in its message, and
    /// the request holds the dictation (`errorDetail(in:key:)` is for the log).
    public static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let said = ((object["error"] as? [String: Any])?["message"] as? String) ?? (object["error"] as? String) ?? (object["message"] as? String)
        return said.map { String($0.prefix(200)) }
    }

    /// What of an error answer may go into the log: its `type`, `code` and
    /// `status` as "type=…, code=…", the same fields and the same rule as
    /// Windows and Linux (`providerDetail`). Never the message, whatever it
    /// holds: a provider may quote the request in it, and the request holds
    /// the dictation. A value is logged only if it is a short token (letters,
    /// digits and `_.:-`, 64 at most, so no sentence that echoes the
    /// dictation) and does not contain the key.
    public static func errorDetail(in data: Data, key: String? = nil) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        let secret = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String] = []
        for name in ["type", "code", "status"] {
            let token: String
            switch error[name] {
            case let text as String: token = text
            // A JSON boolean is an NSNumber too: not a code.
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): token = number.stringValue
            default: continue
            }
            guard isToken(token), secret.count < 8 || !token.contains(secret) else { continue }
            fields.append("\(name)=\(token)")
        }
        return fields.isEmpty ? nil : fields.joined(separator: ", ")
    }

    private static func isToken(_ text: String) -> Bool {
        (1 ... 64).contains(text.utf8.count) && text.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0))) || "_.:-".unicodeScalars.contains($0)
        }
    }
}
