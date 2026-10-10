import Foundation

/// Azure AI Speech's fast transcription, which is where Microsoft runs
/// MAI-Transcribe 2 for anyone with a Speech resource of their own:
/// `POST {host}/speechtotext/transcriptions:transcribe?api-version=…` with
/// the audio and a JSON `definition` as two multipart parts, and the key in
/// `Ocp-Apim-Subscription-Key`. Its documented shapes (Microsoft Learn, REST
/// reference 2025-10-15), not yet tried against the live service: satz has
/// no key of its own to try it with.
public enum MicrosoftSpeech {

    public static let apiVersion = "2025-10-15"
    public static let path = "speechtotext/transcriptions:transcribe"

    /// The model ids in satz's menu. Microsoft names no deployment: the model
    /// is chosen inside the request (`enhancedMode.model`).
    public static let mai2 = "mai-transcribe-2"
    /// Fast transcription without `enhancedMode`: Azure's own, multilingual.
    public static let plain = "azure-speech"

    // MARK: - Where

    public struct Region: Identifiable, Hashable, Sendable {
        /// The id in the host name: `northeurope`.
        public let id: String
        public let name: String
    }

    /// The regions that run MAI-Transcribe (Microsoft Learn, "Speech service
    /// regions", 10.10.2026). A key only works in the region of its resource.
    public static let regions: [Region] = [
        Region(id: "northeurope", name: "North Europe (EU)"),
        Region(id: "eastus", name: "East US"),
        Region(id: "westus", name: "West US"),
        Region(id: "westus2", name: "West US 2"),
        Region(id: "centralindia", name: "Central India"),
        Region(id: "southeastasia", name: "Southeast Asia"),
    ]

    /// The one in the EU.
    public static let defaultRegion = "northeurope"

    /// Region ids are lowercase letters and digits; anything else would
    /// change the host the key is sent to.
    static func isRegionID(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) && !$0.isUppercase }
    }

    /// The host a request goes to: the user's own address if they typed one
    /// (it wins over the region), else the region's regional host. nil when
    /// an address was typed and is not usable, so the key never goes to the
    /// region instead of where the user pointed it.
    public static func baseURL(region: String, endpoint: String) -> URL? {
        if !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return endpointURL(endpoint) }
        let id = isRegionID(region) ? region : defaultRegion
        return URL(string: "https://\(id).api.cognitive.microsoft.com")
    }

    /// A resource address as Azure shows it (`https://name.cognitiveservices.azure.com`),
    /// with or without the scheme, reduced to scheme, host and port. https
    /// only: the key travels in a header.
    public static func endpointURL(_ text: String) -> URL? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.contains("://") { typed = "https://" + typed }
        guard let url = URL(string: typed), url.scheme?.lowercased() == "https",
              let host = url.host, host.contains(".") else { return nil }
        var base = URLComponents()
        base.scheme = "https"
        base.host = host
        base.port = url.port
        return base.url
    }

    /// `base` + the transcription path + the API version.
    static func requestURL(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.percentEncodedPath = (components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath) + "/" + path
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        return components.url ?? base
    }

    // MARK: - The request

    /// What `enhancedMode.model` is called for a menu id; nil for plain fast
    /// transcription. An id typed in by hand ("MAI-Transcribe-3" one day) is
    /// sent as typed.
    static func enhancedModel(for id: String) -> String? {
        let typed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        switch typed.lowercased() {
        case "", plain: return nil
        case mai2: return "MAI-Transcribe-2"
        default: return typed
        }
    }

    /// The `definition` part. No `locales`: Microsoft treats one as a very
    /// strong hint, and a sentence that switches between German and English
    /// would be mangled (the other providers are not told a language either).
    static func definition(model: String, removesFillers: Bool, vocabulary: [String]) -> String {
        var definition: [String: Any] = [:]
        if let enhanced = enhancedModel(for: model) {
            var mode: [String: Any] = ["enabled": true, "model": enhanced]
            // Only MAI-Transcribe 2 takes the style; 1.5 refused the whole
            // request when it came along.
            if model.lowercased().contains(mai2) {
                mode["modelOptions"] = ["transcribeStyle": removesFillers ? "clean" : "verbatim"]
            }
            definition["enhancedMode"] = mode
        }
        if !vocabulary.isEmpty { definition["phraseList"] = ["phrases": vocabulary] }
        let data = try? JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: - The answer

    /// `combinedPhrases[].text`, one per channel, joined. An answer with the
    /// list but no words in it (silence) is "", like the other providers'
    /// empty answers; one without the list falls back to `phrases`.
    static func text(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["combinedPhrases", "phrases"] {
            guard let list = object[key] as? [[String: Any]] else { continue }
            return list.compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return nil
    }
}
