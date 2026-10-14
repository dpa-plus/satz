import Foundation

/// Turns recorded audio into text, using any provider that speaks OpenAI's
/// transcription API, OpenRouter's JSON flavour of it, Azure AI Speech's fast
/// transcription (Microsoft) or the Gemini API (Google).
///
/// One request, one timeout, one result. There is deliberately no second model
/// rewriting the transcript: what you said is what you get.
public struct Transcriber: Sendable {

    /// How the audio travels. The first two go to `{base}/audio/transcriptions`.
    public enum Format: Sendable, Equatable {
        /// OpenAI's own: a multipart file upload. Also Groq and most copies.
        case multipart
        /// OpenRouter's: JSON with the audio base64-encoded. It takes multipart
        /// too, but then drops `prompt` and has nowhere to put provider options,
        /// so the word list and clean mode would be lost.
        case openRouter
        /// Microsoft's: a multipart upload of `audio` and a JSON `definition`
        /// to Azure AI Speech, the key in `Ocp-Apim-Subscription-Key`
        /// (`MicrosoftSpeech`).
        case azureSpeech
        /// Google's: JSON with the audio inline to the Gemini API's
        /// `interactions`, the key in `x-goog-api-key` (`GeminiTranscribe`).
        case gemini
    }

    public struct Settings: Sendable {
        public var model: String = Provider.openAI.defaultModel
        public var baseURL: URL = Provider.openAI.baseURL!
        public var format: Format = .multipart
        /// Every request is bounded, in total: headers and the whole answer.
        /// A dictation tool that can hang is worse than one that fails,
        /// because you cannot tell hung from slow. Long recordings get more
        /// on top, see `timeout(for:)`.
        public var timeout: TimeInterval = 30
        /// Names, jargon and spellings to bias recognition towards. Sent as the
        /// endpoint's own hint (`prompt`, MAI's phrase list or Gemini's custom
        /// vocabulary), not to a second model.
        public var vocabulary: [String] = []
        /// MAI-Transcribe's clean style (and Gemini's smart mode): drops
        /// fillers, stutters and false starts, keeps every word that carries
        /// meaning. Ignored by models that do not have it.
        public var removesFillers = true
        /// Tries per request when the provider throttles. MAI-Transcribe
        /// answers 429 "retry after 2 seconds" now and then, even when idle,
        /// and the next try goes through.
        public var attempts = 3
        /// How long to wait before asking a second time, with the same audio.
        /// MAI-Transcribe usually answers in one or two seconds but now and
        /// then takes ten or more for the same kind of audio (13 of 77 real
        /// dictations over five seconds, one 15.6 s); a second request is
        /// usually back long before. The first answer wins. nil: never.
        /// OpenRouter only, where this was measured; plus the time the upload
        /// itself takes, see `backupDelay(after:for:)`.
        public var backupAfter: TimeInterval? = 2.5

        public init() {}

        /// Settings for `provider`. `customBaseURL` is used only by `.custom`,
        /// and an empty `model` falls back to the provider's default. The
        /// region and the address are Microsoft's: the address, if there is
        /// one, wins over the region.
        public init(provider: Provider, model: String = "", customBaseURL: URL? = nil,
                    microsoftRegion: String = MicrosoftSpeech.defaultRegion, microsoftEndpoint: String = "") {
            if provider == .microsoft {
                // Never the region's host when an address was typed and is
                // unusable: the key would go somewhere the user did not point.
                baseURL = MicrosoftSpeech.baseURL(region: microsoftRegion, endpoint: microsoftEndpoint) ?? Self.missingAddress
            } else if let url = provider.baseURL {
                baseURL = url
            } else if provider == .custom {
                // The same reading of the text that let Custom be chosen
                // (`ProviderReadiness.sendableAddress`): what the audio and
                // the key go to is what was checked, and nothing else.
                baseURL = customBaseURL.flatMap { ProviderReadiness.sendableAddress($0.absoluteString) } ?? Self.missingAddress
            }
            let chosen = model.trimmingCharacters(in: .whitespaces)
            self.model = chosen.isEmpty ? provider.defaultModel : chosen
            format = switch provider {
            case .openRouter: .openRouter
            case .microsoft: .azureSpeech
            case .google: .gemini
            default: .multipart
            }
        }

        /// Never OpenAI's address: a custom key and the recording went there
        /// when the address was cleared. This host cannot exist.
        private static let missingAddress = URL(string: "https://address-missing.invalid")!

        /// The base timeout plus a second per two seconds of audio: a five
        /// minute ramble is a 9.6 MB upload and should not fail at 30 seconds.
        /// This is also the total the call is held to (`send`), upload
        /// included, so it has to cover a slow uplink: a quarter (a second
        /// per four seconds) gave five minutes 105 s, which a line under
        /// 0.7 Mbit/s cannot carry them in; half gives 180 s, enough down to
        /// about 0.5 Mbit/s with the answer still to come.
        func timeout(for wav: Data) -> TimeInterval {
            timeout + Double(max(0, wav.count - 44)) / 32_000 / 2
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noKey
        case unauthorized
        /// Microsoft answered 401 or 403: the key is not one of the Speech
        /// resource in that region (or at that address). Azure cannot tell
        /// the two apart.
        case keyOrRegionWrong
        case rateLimited
        case offline
        case timedOut
        case server(status: Int, message: String?)
        /// The address answered with a redirect that was not followed: to
        /// another origin (the key stays where it was sent), or past the
        /// third hop (`StaysOnOrigin`). A wrong address, which Retry cannot fix
        /// until it is changed.
        case redirected
        case unreadableResponse
        /// The provider's upload limit (OpenAI and Groq take 25 MB, about 13
        /// minutes): Retry would fail the same way, until another provider is
        /// chosen.
        case tooLarge
        /// The account is empty (OpenRouter 402, OpenAI 429 insufficient_quota),
        /// not a provider that is busy for a moment.
        case noCredit

        /// Whether asking again with the same audio and the same provider can
        /// work. A recording over the upload limit never will; a throttled,
        /// offline or rejected request does once the cause is gone.
        public var retryHelps: Bool { self != .tooLarge }

        /// Non-optional, so callers never have to invent a fallback string.
        public var message: String {
            switch self {
            case .noKey: de("Kein API-Schlüssel hinterlegt.", en: "No API key saved.")
            case .unauthorized: de("Der API-Schlüssel wird abgelehnt.", en: "The API key was rejected.")
            case .keyOrRegionWrong: de("Schlüssel oder Region falsch.", en: "Key or region wrong.")
            case .rateLimited: de("Der Anbieter drosselt gerade. Kurz warten.", en: "The provider is throttling. Wait a moment.")
            case .offline: de("Keine Verbindung zum Anbieter.", en: "No connection to the provider.")
            case .timedOut: de("Der Anbieter hat nicht rechtzeitig geantwortet.", en: "The provider did not answer in time.")
            case .server(let status, let message): message ?? de("Der Anbieter antwortete mit \(status).", en: "The provider answered with \(status).")
            // The long version, for the log; the card has `short`.
            case .redirected: de("Der Anbieter verweist auf eine andere Adresse. Die Adresse prüfen.", en: "The provider points to another address. Check the address.")
            case .unreadableResponse: de("Antwort des Anbieters nicht lesbar.", en: "Could not read the provider's answer.")
            // The audio is still there: another provider takes it with the
            // shortcut, no need to say it again. There is no text to copy.
            case .tooLarge: de("Die Aufnahme ist zu lang für den Anbieter. Einen anderen Anbieter wählen und noch einmal senden.", en: "The recording is too long for the provider. Pick another provider and send it again.")
            case .noCredit: de("Kein Guthaben beim Anbieter. Dort aufladen.", en: "No credit left at the provider. Top it up there.")
            }
        }

        public var errorDescription: String? { message }
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
        // Gemini takes the audio inline up to 20 MB: past that, say so now
        // instead of uploading 20 MB to be refused.
        if settings.format == .gemini, GeminiTranscribe.isTooLarge(wav: wav, vocabulary: settings.vocabulary, model: settings.model,
                                                                   removesFillers: settings.removesFillers) {
            throw Failure.tooLarge
        }
        // Counted from the start of the upload, so a long recording, whose
        // upload alone takes a while, waits longer before a second copy goes.
        guard settings.format == .openRouter, let base = settings.backupAfter else { return try await attempt(wav: wav, apiKey: apiKey) }
        let delay = Self.backupDelay(after: base, for: wav)

        enum Event: Sendable {
            case answer(Result<String, any Error>)
            case timer
        }
        let ask: @Sendable () async -> Event = {
            do { return .answer(.success(try await attempt(wav: wav, apiKey: apiKey))) } catch { return .answer(.failure(error)) }
        }
        return try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask(operation: ask)
            group.addTask {
                try await Task.sleep(for: .seconds(delay))
                return .timer
            }
            var running = 1
            var backedUp = false
            var firstFailure: (any Error)?
            while let event = try await group.next() {
                switch event {
                case .timer:
                    guard running > 0 else { continue }
                    backedUp = true
                    running += 1
                    group.addTask(operation: ask)
                case .answer(.success(let text)):
                    group.cancelAll()
                    return text
                case .answer(.failure(let error)):
                    running -= 1
                    firstFailure = firstFailure ?? error
                    // A failure before the second request went out is the
                    // answer: rejected keys and the like do not get better.
                    if !backedUp || running == 0 {
                        group.cancelAll()
                        throw firstFailure ?? error
                    }
                }
            }
            throw firstFailure ?? Failure.unreadableResponse
        }
    }

    /// `base` plus the time the upload takes at 1 Mbit/s: on a slow line the
    /// second copy started while the first was still sending, and both ran
    /// out of time sharing it. About 2.6 s more for ten seconds of audio.
    static func backupDelay(after base: TimeInterval, for wav: Data) -> TimeInterval {
        base + Double(max(0, wav.count - 44)) * 8 / 1_000_000
    }

    /// One request, tried again while the provider throttles.
    private func attempt(wav: Data, apiKey: String) async throws -> String {
        let request = makeRequest(wav: wav, apiKey: apiKey)
        var attempt = 1
        while true {
            let (data, http) = try await send(request)
            if http.statusCode == 402 || (http.statusCode == 429 && String(decoding: data, as: UTF8.self).contains("insufficient_quota")) {
                throw Failure.noCredit
            }
            if http.statusCode == 429, attempt < settings.attempts {
                attempt += 1
                try await Task.sleep(for: .seconds(Self.retryDelay(http: http, body: data)))
                continue
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw Self.failure(status: http.statusCode, body: data, format: settings.format)
            }
            guard let text = Self.text(in: data, format: settings.format) else { throw Failure.unreadableResponse }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            // `timeoutInterval` is the longest silence, not the longest wait:
            // every chunk of a slowly dripping answer starts it again (34 s
            // went by under a 30 s limit). The same number is the total
            // here, headers and body.
            (data, response) = try await Self.within(request.timeoutInterval) { [session] in
                try await session.data(for: request, delegate: StaysOnOrigin())
            }
        } catch let error as URLError {
            throw Self.translate(error)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableResponse }
        return (data, http)
    }

    private enum Race<T: Sendable>: Sendable {
        case done(T)
        case expired
        // The clock was cancelled with everything else: not an expiry.
        case stopped
    }

    /// `work` against a clock. When the clock wins, `work` is cancelled,
    /// which for a URLSession call drops the connection, and the caller gets
    /// `timedOut` (the recording stays for Retry like for any failure).
    private static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: Race<T>.self) { group in
            // Cancelled on the way out whichever way it goes: the group
            // would otherwise wait for the one still running.
            defer { group.cancelAll() }
            group.addTask { .done(try await work()) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return .stopped }
                return .expired
            }
            while let outcome = try await group.next() {
                switch outcome {
                case .done(let value): return value
                case .expired: throw Failure.timedOut
                case .stopped: continue
                }
            }
            throw URLError(.cancelled)
        }
    }

    /// Keeps a request where it was sent. Every request carries a key and the
    /// recording, and URLSession hands any header except `Authorization` on
    /// to a redirect target (Microsoft's and Google's key headers went to
    /// another host that way), so a redirect to another origin is not
    /// followed: the 3xx answer comes back and is reported
    /// (`Failure.redirected`). A redirect within the origin (a trailing slash,
    /// a moved path) is followed, but only three times: a loop is not a
    /// route, and the fourth answer comes back like a refused one.
    final class StaysOnOrigin: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let hops = 3

        // One instance per request. URLSession calls a task's delegate one
        // call at a time, the lock is for the compiler's sake.
        private let lock = NSLock()
        private var followed = 0

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // Against where the request started, not against the last hop.
            guard Self.sameOrigin(task.originalRequest?.url, request.url), follow() else { return completionHandler(nil) }
            var next = request
            // URLSession leaves `Authorization` behind on every redirect, this
            // one too; the Bearer providers (OpenAI, Groq, most custom
            // endpoints) would answer the second request with a 401. It stays
            // on the origin the key was meant for, so the key goes along.
            if next.value(forHTTPHeaderField: "Authorization") == nil,
               let key = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
                next.setValue(key, forHTTPHeaderField: "Authorization")
            }
            completionHandler(next)
        }

        /// Whether one more hop is allowed; counts it.
        private func follow() -> Bool {
            lock.withLock {
                guard followed < Self.hops else { return false }
                followed += 1
                return true
            }
        }

        static func sameOrigin(_ first: URL?, _ second: URL?) -> Bool {
            guard let first, let second, let from = origin(first) else { return false }
            return from == origin(second)
        }

        private static func origin(_ url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
            return "\(scheme)://\(host):\(port)"
        }
    }

    // MARK: - Private

    func makeRequest(wav: Data, apiKey: String) -> URLRequest {
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeout(for: wav)

        switch settings.format {
        case .multipart:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            var fields: [(name: String, value: String)] = [("model", settings.model)]
            let words = settings.vocabulary.joined(separator: ", ")
            if !words.isEmpty { fields.append(("prompt", words)) }
            fields.append(("response_format", "json"))

            let body = MultipartBody()
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body.encode(fields: fields, file: ("file", "speech.wav", "audio/wav", wav))

        case .openRouter:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: openRouterBody(wav: wav), options: [.sortedKeys, .withoutEscapingSlashes])

        case .azureSpeech:
            request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            let definition = MicrosoftSpeech.definition(model: settings.model, removesFillers: settings.removesFillers,
                                                        vocabulary: settings.vocabulary)
            let body = MultipartBody()
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body.encode(fields: [("definition", definition)], file: ("audio", "speech.wav", "audio/wav", wav),
                                           fileFirst: true)

        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = GeminiTranscribe.body(wav: wav, model: settings.model, vocabulary: settings.vocabulary,
                                             removesFillers: settings.removesFillers)
            request.httpBody = GeminiTranscribe.encode(body)
        }
        return request
    }

    private var requestURL: URL {
        switch settings.format {
        case .multipart, .openRouter: settings.baseURL.appendingPathComponent("audio/transcriptions")
        case .azureSpeech: MicrosoftSpeech.requestURL(base: settings.baseURL)
        case .gemini: settings.baseURL.appendingPathComponent("interactions")
        }
    }

    /// OpenRouter forwards `provider.options.<slug>` only to that provider, so
    /// the Azure block reaches MAI-Transcribe and nothing else.
    func openRouterBody(wav: Data) -> [String: Any] {
        var azure: [String: Any] = [
            "enhancedMode": ["modelOptions": ["transcribeStyle": settings.removesFillers ? "clean" : "verbatim"]],
        ]
        if !settings.vocabulary.isEmpty {
            azure["phraseList"] = ["phrases": settings.vocabulary]
        }
        var body: [String: Any] = [
            "model": settings.model,
            "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
        ]
        // Only MAI-Transcribe 2 takes these: MAI-Transcribe 1.5, also at
        // Azure, refused the whole request when they came along.
        if settings.model.contains("mai-transcribe-2") {
            body["provider"] = ["options": ["azure": azure]]
        }
        // For models other than MAI. OpenRouter documents it as ignored for
        // multipart; in JSON it costs nothing to offer.
        if !settings.vocabulary.isEmpty { body["prompt"] = settings.vocabulary.joined(separator: ", ") }
        return body
    }

    /// How long the provider asks us to wait: the Retry-After header, or
    /// OpenRouter's copy of it in the body. Capped, because a dictation that
    /// sits for a minute is worse than one that says it failed.
    static func retryDelay(http: HTTPURLResponse, body: Data) -> Double {
        let header = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        let metadata = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["metadata"] as? [String: Any] }
            .flatMap { $0["retry_after_seconds"] as? Double }
        return min(5, max(0, header ?? metadata ?? 2))
    }

    static func translate(_ error: URLError) -> Failure {
        switch error.code {
        case .timedOut: .timedOut
        // Plain http to a named host (http://whisper.fritz.box): macOS refuses it.
        case .appTransportSecurityRequiresSecureConnection:
            .server(status: error.errorCode, message: de("Diese Adresse braucht https.", en: "This address needs https."))
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
            .offline
        default: .server(status: error.errorCode, message: error.localizedDescription)
        }
    }

    static func failure(status: Int, body: Data, format: Format = .multipart) -> Failure {
        let said = message(in: body)
        switch status {
        // Azure says 401 for a key from another region too, and for a wrong
        // address: it cannot be told which.
        case 401, 403: return format == .azureSpeech ? .keyOrRegionWrong : .unauthorized
        case 429: return .rateLimited
        case 413: return .tooLarge
        // A redirect that is not followed (`StaysOnOrigin`) comes back as it
        // is: the key stays where it was sent. What is left is a wrong address.
        case 300 ..< 400:
            return .redirected
        case 400 where format == .gemini && (said.map(namesTheKey) == true || String(decoding: body, as: UTF8.self).contains("API_KEY_INVALID")):
            // Google answers a key it does not know with 400 INVALID_ARGUMENT.
            return .unauthorized
        case 400 where (format == .azureSpeech || format == .gemini) && said.map(namesASizeLimit) == true:
            // Both refuse a request over their limit as a plain 400.
            return .tooLarge
        default: return .server(status: status, message: said)
        }
    }

    private static func namesTheKey(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("api key") && (text.contains("not valid") || text.contains("invalid") || text.contains("expired"))
    }

    private static func namesASizeLimit(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["too large", "too long", "payload size", "request size", "file size", "exceeds the maximum", "exceeds the limit"]
            .contains { text.contains($0) }
    }

    /// OpenAI returns `{"error": {"message": "..."}}` on failure; Azure's
    /// fast transcription also `{"code": "...", "message": "..."}`.
    static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["message"] as? String
    }

    /// The transcript out of a success: `{"text": "..."}` for the OpenAI
    /// shape, which is what OpenRouter answers in too.
    static func text(in data: Data, format: Format) -> String? {
        switch format {
        case .multipart, .openRouter: text(in: data)
        case .azureSpeech: MicrosoftSpeech.text(in: data)
        case .gemini: GeminiTranscribe.text(in: data)
        }
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
