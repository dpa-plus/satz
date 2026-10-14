import Foundation

/// Where the text goes to be cleaned up: a cloud provider, a server on this
/// computer, or Apple's model on this Mac.
///
/// Three request shapes cover them all (`Family`): most copy OpenAI's chat
/// completions, Anthropic and Google have their own. Apple's model is Mac
/// only: there is nothing like it on Windows or Linux.
public enum CleanupProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case apple
    case openRouter = "openrouter"
    case openAI = "openai"
    case anthropic
    case google
    case groq
    case cerebras
    case mistral
    case deepseek
    case xai
    case azure
    case ollama
    case lmStudio = "lmstudio"
    case custom

    public var id: String { rawValue }

    public enum Family: Sendable, Equatable {
        /// `POST {base}/chat/completions`, OpenAI's shape. Most providers copy it.
        case openAI
        /// `POST /v1/messages`.
        case anthropic
        /// `POST /models/{model}:generateContent`.
        case gemini
        /// FoundationModels, on this Mac.
        case apple
    }

    /// The menu, in its order. Apple's model needs macOS 26.
    public static var menu: [CleanupProvider] {
        if #available(macOS 26, *) { return allCases }
        return allCases.filter { $0 != .apple }
    }

    public var name: String { name(in: .current) }

    public func name(in language: Language) -> String {
        let english = language == .english
        return switch self {
        case .apple: english ? "Apple (on this Mac)" : "Apple (auf dem Mac)"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google"
        case .groq: "Groq"
        case .cerebras: "Cerebras"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .xai: "xAI"
        case .azure: "Microsoft Azure"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: english ? "Custom" : "Eigener"
        }
    }

    /// For buttons: "Apple benutzen", not "Apple (auf dem Mac) benutzen".
    public func shortName(in language: Language) -> String {
        self == .apple ? "Apple" : name(in: language)
    }

    public var family: Family {
        switch self {
        case .apple: .apple
        case .anthropic: .anthropic
        case .google: .gemini
        default: .openAI
        }
    }

    /// The transcription provider whose key file this provider reads too.
    public var sharesKey: Provider? {
        switch self {
        case .openRouter: .openRouter
        case .openAI: .openAI
        case .google: .google
        case .groq: .groq
        default: nil
        }
    }

    /// nil for the ones on this computer, which take no key.
    public var keyAccount: KeyAccount? {
        // The same file, without the transcription's note: Google's speaks of
        // the audio, while cleanup sends text, which the model's line covers.
        if let shared = sharesKey { return KeyAccount(shared.keychainAccount, placeholder: shared.keyPlaceholder, page: shared.keyPage) }
        return switch self {
        case .anthropic: KeyAccount("anthropic", placeholder: "sk-ant-…", page: URL(string: "https://console.anthropic.com/settings/keys"))
        case .cerebras: KeyAccount("cerebras", placeholder: "csk-…", page: URL(string: "https://cloud.cerebras.ai/"))
        case .mistral: KeyAccount("mistral", placeholder: de("API-Schlüssel", en: "API key"), page: URL(string: "https://console.mistral.ai/api-keys"))
        case .deepseek: KeyAccount("deepseek", placeholder: "sk-…", page: URL(string: "https://platform.deepseek.com/api_keys"))
        case .xai: KeyAccount("xai", placeholder: "xai-…", page: URL(string: "https://console.x.ai/"))
        case .azure: KeyAccount("azure-openai", placeholder: de("API-Schlüssel", en: "API key"),
                                note: de("Ein Schlüssel einer Azure-OpenAI- oder Foundry-Ressource, nicht der Speech-Schlüssel.",
                                         en: "A key of an Azure OpenAI or Foundry resource, not the Speech key."))
        // A server of the user's own may or may not want one.
        case .custom: KeyAccount("custom-cleanup", placeholder: de("API-Schlüssel (optional)", en: "API key (optional)"), isOptional: true)
        default: nil
        }
    }

    /// Without a key nothing can be sent.
    public var needsKey: Bool { keyAccount.map { !$0.isOptional } ?? false }

    /// The address is the user's: their Azure resource, their own server.
    public var hasAddress: Bool {
        switch self {
        case .azure, .ollama, .lmStudio, .custom: true
        default: false
        }
    }

    /// Where Ollama and LM Studio listen unless told otherwise.
    public var defaultAddress: String {
        switch self {
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        default: ""
        }
    }

    /// The address requests go to: the one typed, or while the field is
    /// empty Ollama's and LM Studio's own. Settings and the dictation ask
    /// this alike, so "Adresse fehlt" never shows for one that would work.
    public func address(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultAddress : typed
    }

    /// The fixed address of a cloud provider. DeepSeek's path has no /v1.
    public var fixedBase: URL? {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .anthropic: URL(string: "https://api.anthropic.com/v1")
        case .google: URL(string: "https://generativelanguage.googleapis.com/v1beta")
        case .groq: URL(string: "https://api.groq.com/openai/v1")
        case .cerebras: URL(string: "https://api.cerebras.ai/v1")
        case .mistral: URL(string: "https://api.mistral.ai/v1")
        case .deepseek: URL(string: "https://api.deepseek.com")
        case .xai: URL(string: "https://api.x.ai/v1")
        case .apple, .azure, .ollama, .lmStudio, .custom: nil
        }
    }

    /// The model used until another is picked. Empty where the user names it
    /// (an Azure deployment, an own server) or the server lists it (Ollama's
    /// first installed model).
    public var defaultModel: String {
        CleanupCatalog.models(for: self).first?.id ?? (self == .apple ? CleanupCatalog.appleModel : "")
    }

    /// The model runs on this computer: no key, free, and the first call
    /// loads it, so it gets the long timeout.
    public var runsHere: Bool {
        switch self {
        case .apple, .ollama, .lmStudio: true
        default: false
        }
    }

    /// Which provider cleans up until the user picks one: the one that
    /// transcribes if it can (its key is there already), else OpenRouter if
    /// its key is there, else Apple's model on a Mac that has it.
    public static func standard(transcription: Provider, hasOpenRouterKey: Bool, appleAvailable: Bool) -> CleanupProvider {
        switch transcription {
        case .openRouter: return .openRouter
        case .openAI: return .openAI
        case .google: return .google
        case .groq: return .groq
        default: break
        }
        if hasOpenRouterKey { return .openRouter }
        return appleAvailable ? .apple : .openRouter
    }
}

// MARK: - The switch under the menu

/// The row under the cleanup providers while one is shown that is not in
/// use, worded like the transcription's (`SwitchWording`).
public enum CleanupSwitchWording {

    public static func goesTo(_ inUse: CleanupProvider, in language: Language = .current) -> String {
        let name = inUse.name(in: language)
        if language == .english { return inUse == .custom ? "Cleanup goes to “\(name)”." : "Cleanup goes to \(name)." }
        return inUse == .custom ? "Aufräumen geht an „\(name)“." : "Aufräumen geht an \(name)."
    }

    public static func button(_ shown: CleanupProvider, in language: Language = .current) -> String {
        if language == .english { return "Use \(shown.shortName(in: language))" }
        return shown == .custom ? "Eigenen benutzen" : "\(shown.shortName(in: language)) benutzen"
    }
}

/// What "Ausprobieren" starts with: a dictation with a filler, a
/// self-correction and a question, in the language spoken.
public enum CleanupSample {
    public static func text(for language: Language) -> String {
        language == .english
            ? "um so i wanted to ask if we can move the meeting to monday no tuesday and can you tell me who else is coming"
            : "ähm also ich wollte fragen ob wir das meeting am montag nein am dienstag machen können und kannst du mir sagen wer noch kommt"
    }
}

// MARK: - Addresses

/// The address a key and the text are sent to: https, or plain http to this
/// computer only (Ollama, LM Studio, a server of the user's own). Plain http
/// anywhere else would carry the key and the text in the clear.
public enum CleanupAddress {

    /// The address as typed, made usable, or nil. Without a scheme https is
    /// meant. Reduced the way Windows and Linux do (`usableAddress`): scheme
    /// and host in lower case, no user info (a key must not travel with one),
    /// no query or fragment, no port that is the scheme's own, no slash at
    /// the end; the path stays.
    public static func url(_ text: String) -> URL? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if !typed.contains("://") { typed = "https://" + typed }
        guard var parts = URLComponents(string: typed), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        switch scheme {
        case "https": break
        // http only on this computer or the own network, like every address
        // a key travels to (`ProviderAddress`): an Ollama on the NAS is fine.
        case "http": guard ProviderAddress.allows(scheme: "http", host: host) else { return nil }
        default: return nil
        }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let port = parts.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : $0 }
        parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = port
        parts.percentEncodedPath = path
        return parts.url
    }

    public static func isUsable(_ text: String) -> Bool { url(text) != nil }

    /// localhost, 127.0.0.1 or ::1.
    public static func isThisComputer(_ url: URL) -> Bool {
        isThisComputer(host: url.host ?? "")
    }

    private static func isThisComputer(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// An Azure resource address as the portal shows it, reduced to scheme,
    /// host and port: the request path is satz's (`/openai/v1/...`).
    public static func azureOrigin(_ text: String) -> URL? {
        guard let url = url(text) else { return nil }
        var origin = URLComponents()
        origin.scheme = url.scheme
        origin.host = url.host
        origin.port = url.port
        return origin.url
    }
}

// MARK: - What is missing

/// What a cleanup provider lacks before it can take a text: the same words
/// as the transcription provider's (`ProviderReadiness`), plus Apple's model
/// being there.
public enum CleanupReadiness {

    public enum Need: Equatable, Sendable {
        case key
        case address
        case model
        case apple(AppleCleanup.State)
    }

    public static func missing(_ provider: CleanupProvider, hasKey: Bool, address: String, model: String,
                               apple: AppleCleanup.State = .available) -> [Need] {
        if provider == .apple { return apple == .available ? [] : [.apple(apple)] }
        var needs: [Need] = []
        if provider.needsKey, !hasKey { needs.append(.key) }
        if provider.hasAddress {
            let effective = provider.address(address)
            let usable = provider == .azure ? CleanupAddress.azureOrigin(effective) != nil : CleanupAddress.isUsable(effective)
            if !usable { needs.append(.address) }
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { needs.append(.model) }
        return needs
    }

    public static func message(_ needs: [Need], in language: Language = .current) -> String? {
        if case .apple(let state)? = needs.first { return state.message(in: language) }
        let plain = needs.compactMap { need -> ProviderReadiness.Need? in
            switch need {
            case .key: .key
            case .address: .address
            case .model: .model
            case .apple: nil
            }
        }
        return ProviderReadiness.message(plain, in: language)
    }
}
