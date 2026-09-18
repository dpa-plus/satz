import Foundation

/// Turns recorded audio into text using OpenAI's transcription endpoint.
///
/// One request, one timeout, one result. There is deliberately no second model
/// rewriting the transcript: what you said is what you get.
public struct Transcriber: Sendable {

    public struct Settings: Sendable {
        public var model: String = "gpt-transcribe"
        public var baseURL: URL = URL(string: "https://api.openai.com/v1")!
        /// Every request is bounded. A dictation tool that can hang is worse
        /// than one that fails, because you cannot tell hung from slow.
        public var timeout: TimeInterval = 30
        /// Names, jargon and spellings to bias recognition towards. This is the
        /// endpoint's own `prompt` parameter, not a second model.
        public var vocabulary: String = ""
        /// nil lets the model detect the language, which is what you want if
        /// you switch languages mid-sentence.
        public var language: String?

        public init() {}
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noKey
        case unauthorized
        case rateLimited
        case offline
        case timedOut
        case server(status: Int, message: String?)
        case unreadableResponse

        public var errorDescription: String? {
            switch self {
            case .noKey: "Kein OpenAI-Schlüssel hinterlegt."
            case .unauthorized: "Der OpenAI-Schlüssel wird abgelehnt."
            case .rateLimited: "OpenAI drosselt gerade. Kurz warten."
            case .offline: "Keine Verbindung zu OpenAI."
            case .timedOut: "OpenAI hat nicht rechtzeitig geantwortet."
            case .server(let status, let message): message ?? "OpenAI antwortete mit \(status)."
            case .unreadableResponse: "Antwort von OpenAI nicht lesbar."
            }
        }
    }

    public var settings: Settings
    private let session: URLSession

    public init(settings: Settings = Settings(), session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    /// - Parameter wav: 16-bit PCM WAV bytes, as produced by `WAVEncoder`.
    public func transcribe(wav: Data, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure.noKey }

        let request = makeRequest(wav: wav, apiKey: apiKey)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.translate(error)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: data)
        }
        guard let text = Self.text(in: data) else { throw Failure.unreadableResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    func makeRequest(wav: Data, apiKey: String) -> URLRequest {
        var fields: [(name: String, value: String)] = [("model", settings.model)]
        if !settings.vocabulary.isEmpty { fields.append(("prompt", settings.vocabulary)) }
        if let language = settings.language { fields.append(("language", language)) }
        fields.append(("response_format", "json"))

        let body = MultipartBody()
        var request = URLRequest(url: settings.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.encode(
            fields: fields,
            file: ("file", "speech.wav", "audio/wav", wav)
        )
        return request
    }

    static func translate(_ error: URLError) -> Failure {
        switch error.code {
        case .timedOut: .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
            .offline
        default: .server(status: error.errorCode, message: error.localizedDescription)
        }
    }

    static func failure(status: Int, body: Data) -> Failure {
        switch status {
        case 401, 403: .unauthorized
        case 429: .rateLimited
        default: .server(status: status, message: message(in: body))
        }
    }

    /// OpenAI returns `{"error": {"message": "..."}}` on failure.
    static func message(in data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return nil }
        return message
    }

    /// A success is `{"text": "..."}`.
    static func text(in data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["text"] as? String
        else { return nil }
        return text
    }
}
