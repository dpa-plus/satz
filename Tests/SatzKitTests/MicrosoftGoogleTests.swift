import Foundation
import Testing
@testable import SatzKit

// Microsoft (Azure AI Speech) and Google (Gemini API). Neither service was
// called: satz has no key for them. What is tested is the request exactly as
// it goes over the wire (a stand-in HTTP server on 127.0.0.1 records it) and
// the answers as their documentation shows them.

private let wav = Data("RIFF....WAVEfmt fake audio bytes".utf8)

private func json(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

/// The two parts Microsoft's request carries.
private func parts(of request: URLRequest) throws -> MultipartParts {
    let body = try #require(request.httpBody)
    return try #require(MultipartParts(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type")))
}

/// What Microsoft's `definition` part says.
private func definition(of request: URLRequest) throws -> [String: Any] {
    let definition = try #require(try parts(of: request)["definition"])
    return try json(definition.data)
}

/// Gemini's `transcription_config`.
private func transcriptionConfig(of request: URLRequest) throws -> [String: Any] {
    let body = try json(try #require(request.httpBody))
    let generation = try #require(body["generation_config"] as? [String: Any])
    return try #require(generation["transcription_config"] as? [String: Any])
}

private func transcriber(_ settings: Transcriber.Settings, against server: StandInServer? = nil) -> Transcriber {
    var settings = settings
    // The real address stays checked by its own tests; a round trip goes to the stand-in.
    if let server { settings.baseURL = server.baseURL }
    settings.attempts = 3
    return Transcriber(settings: settings)
}

// MARK: - The providers

@Test func sevenProvidersWithMicrosoftAndGoogleBeforeTheUsersOwn() {
    #expect(Provider.allCases.map(\.rawValue) == ["openai", "openrouter", "groq", "microsoft", "google", "custom", "local"])
    #expect(Provider.microsoft.name == "Microsoft" && Provider.google.name == "Google")
    #expect(Provider.allCases.filter(\.needsKey).count == 6)
    // Each keeps a key file of its own.
    #expect(Provider.microsoft.keychainAccount == "microsoft" && Provider.google.keychainAccount == "google")
    #expect(Provider.microsoft.defaultModel == "mai-transcribe-2" && Provider.google.defaultModel == "gemini-3.5-transcribe")
    #expect(Provider.microsoft.keyPage?.absoluteString == "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices")
    #expect(Provider.google.keyPage?.absoluteString == "https://aistudio.google.com/apikey")
}

@Test func microsoftsAndGooglesMenusLeadWithTheDefaultAndCarryTheirPrices() throws {
    let microsoft = Provider.microsoft.models
    #expect(microsoft.map(\.id) == ["mai-transcribe-2", "azure-speech"])
    #expect(microsoft[0].name == "MAI-Transcribe 2" && microsoft[0].maker == "Microsoft" && microsoft[0].errorRate == 2.0)
    // $0.10 an hour while the introductory price lasts (to the end of 2026).
    #expect(microsoft[0].dollarsPerHour == 0.10)
    #expect(microsoft[1].name == "Azure Speech" && microsoft[1].dollarsPerHour == 0.36 && microsoft[1].errorRate == nil)

    let google = try #require(Provider.google.models.first)
    #expect(Provider.google.models.count == 1)
    #expect(google.id == "gemini-3.5-transcribe" && google.name == "Gemini 3.5 Transcribe" && google.maker == "Google")
    #expect(google.dollarsPerHour == 0.30)
}

@Test func maiTranscribe2CostsTheOrdinaryPriceOnceTheIntroductoryOneEnds() {
    let lastDay = Date(timeIntervalSince1970: 1_798_761_599)   // 2026-12-31 23:59:59 UTC
    let firstDay = Date(timeIntervalSince1970: 1_798_761_600)  // 2027-01-01 00:00:00 UTC
    #expect(ModelCatalog.maiPrice(on: lastDay) == 0.10)
    #expect(ModelCatalog.maiPrice(on: firstDay) == 0.36)
}

@Test func theFactsLineSaysWhenMAIsPriceChangesAndTheGooglePriceIsPlain() {
    let price = { (value: Double) in String(format: "$%.2f", value) }
    #expect(ModelCatalog.note(for: "mai-transcribe-2", provider: .microsoft, price: price, language: .english)
            == "Introductory price until 31 Dec 2026, then $0.36 an hour. Public preview.")
    #expect(ModelCatalog.note(for: "mai-transcribe-2", provider: .microsoft, price: price, language: .german)
            == "Einführungspreis bis 31.12.2026, danach $0.36 pro Stunde. Öffentliche Vorschau.")
    #expect(ModelCatalog.note(for: "gemini-3.5-transcribe", provider: .google, price: price) == nil)
    #expect(ModelCatalog.note(for: "gpt-transcribe", provider: .openAI, price: price) == nil)
}

@Test func theKeyNoteWarnsGoogleKeysCanBeFreeAndMicrosoftKeysAreRegional() {
    // In whichever language the app is in just now (it is a global other tests switch).
    let google = Provider.google.keyNote ?? ""
    #expect(google.contains("Abrechnung") || google.contains("billing"))
    let microsoft = Provider.microsoft.keyNote ?? ""
    #expect(microsoft.contains("Region") || microsoft.contains("region"))
    #expect(Provider.openAI.keyNote == nil && Provider.local.keyNote == nil)
    #expect(!google.contains("\u{2014}") && !microsoft.contains("\u{2014}"))
}

@Test func theFillerSwitchIsOnlyOfferedWhereItDoesSomething() {
    #expect(Provider.microsoft.hasFillerSwitch(model: "mai-transcribe-2"))
    #expect(!Provider.microsoft.hasFillerSwitch(model: "azure-speech"))
    #expect(Provider.google.hasFillerSwitch(model: "gemini-3.5-transcribe"))
    #expect(Provider.openRouter.hasFillerSwitch(model: "microsoft/mai-transcribe-2"))
    #expect(!Provider.openRouter.hasFillerSwitch(model: "microsoft/mai-transcribe-1.5"))
    #expect(!Provider.openAI.hasFillerSwitch(model: "gpt-transcribe"))
}

@Test func neitherMicrosoftNorGoogleHasALiveModelList() async throws {
    #expect(!ModelCatalog.hasLiveList(.microsoft) && !ModelCatalog.hasLiveList(.google))
    #expect(ModelCatalog.hasLiveList(.openRouter) && ModelCatalog.hasLiveList(.openAI) && ModelCatalog.hasLiveList(.groq))
    #expect(try await ModelCatalog.fetch(.microsoft, key: "k").isEmpty)
}

// MARK: - Ready to use

@Test func microsoftNeedsItsKeyAndAnAddressOnlyWhenOneWasTypedThatDoesNotWork() {
    let missing = { (hasKey: Bool, endpoint: String) in
        ProviderReadiness.missing(.microsoft, hasKey: hasKey, customBaseURL: "", model: "", microsoftEndpoint: endpoint)
    }
    #expect(missing(true, "") == [])
    #expect(missing(false, "") == [.key])
    #expect(missing(true, "   ") == [])
    #expect(missing(true, "https://mine.cognitiveservices.azure.com") == [])
    // Typed and refused is told apart from nothing typed (`.address`): the message says why.
    #expect(missing(true, "http://mine.cognitiveservices.azure.com") == [.addressRefused])
    #expect(missing(false, "not an address") == [.key, .addressRefused])
    // Google wants its key and nothing else.
    #expect(ProviderReadiness.missing(.google, hasKey: false, customBaseURL: "", model: "") == [.key])
    #expect(ProviderReadiness.missing(.google, hasKey: true, customBaseURL: "", model: "") == [])
}

@Test func theSwitchRowNamesTheNewProviders() {
    #expect(SwitchWording.button(.microsoft, in: .german) == "Microsoft benutzen")
    #expect(SwitchWording.button(.google, in: .english) == "Use Google")
    #expect(SwitchWording.goesTo(.google, in: .german) == "Diktate gehen an Google.")
}

// MARK: - Microsoft: the address

@Test func theRegionBuildsTheRegionalHost() {
    #expect(MicrosoftSpeech.baseURL(region: "northeurope", endpoint: "")?.absoluteString == "https://northeurope.api.cognitive.microsoft.com")
    #expect(MicrosoftSpeech.baseURL(region: "eastus", endpoint: "  ")?.absoluteString == "https://eastus.api.cognitive.microsoft.com")
    // Nothing but a region id goes into the host the key is sent to.
    #expect(MicrosoftSpeech.baseURL(region: "evil.example.com/x", endpoint: "")?.absoluteString == "https://northeurope.api.cognitive.microsoft.com")
    #expect(MicrosoftSpeech.baseURL(region: "", endpoint: "")?.host == "northeurope.api.cognitive.microsoft.com")
}

@Test func theSixRegionsAreTheOnesMAITranscribeRunsIn() {
    #expect(MicrosoftSpeech.regions.map(\.id) == ["northeurope", "eastus", "westus", "westus2", "centralindia", "southeastasia"])
    #expect(MicrosoftSpeech.regions.first?.id == MicrosoftSpeech.defaultRegion)
}

@Test func anOwnAddressWinsOverTheRegion() {
    let base = { (endpoint: String) in MicrosoftSpeech.baseURL(region: "eastus", endpoint: endpoint)?.absoluteString }
    #expect(base("https://satz-speech.cognitiveservices.azure.com") == "https://satz-speech.cognitiveservices.azure.com")
    // As the portal shows it, with a slash, or typed without the scheme.
    #expect(base("https://satz-speech.cognitiveservices.azure.com/") == "https://satz-speech.cognitiveservices.azure.com")
    #expect(base("satz-speech.cognitiveservices.azure.com") == "https://satz-speech.cognitiveservices.azure.com")
    // A pasted full URL is cut down to the host.
    #expect(base("https://westeurope.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
            == "https://westeurope.api.cognitive.microsoft.com")
    #expect(base(" https://x.example.org:8443/ ") == "https://x.example.org:8443")
}

@Test func anAddressThatCannotWorkIsNeverReplacedByTheRegion() {
    // Typed and not usable: nil, so the key does not go to the region's host instead.
    for bad in ["http://satz.cognitiveservices.azure.com", "https://", "ftp://x.example.org", "nonsense", "https://localhost"] {
        #expect(MicrosoftSpeech.baseURL(region: "northeurope", endpoint: bad) == nil, "\(bad)")
    }
    let settings = Transcriber.Settings(provider: .microsoft, microsoftRegion: "northeurope", microsoftEndpoint: "http://insecure.example.org")
    #expect(settings.baseURL.host == "address-missing.invalid")
}

// MARK: - Microsoft: the request

@Test func microsoftsRequestIsTheDocumentedFastTranscriptionCall() throws {
    var settings = Transcriber.Settings(provider: .microsoft)
    settings.vocabulary = ["Kubernetes", "XX"]
    let request = Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "azure-secret")

    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString
            == "https://northeurope.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
    #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "azure-secret")
    // The key is in the header only: not Bearer, never in the address.
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.url?.absoluteString.contains("azure-secret") == false)

    let sent = try parts(of: request)
    #expect(sent.parts.map(\.name) == ["audio", "definition"])
    let audio = try #require(sent["audio"])
    #expect(audio.filename == "speech.wav" && audio.contentType == "audio/wav" && audio.data == wav)

    let definition = try definition(of: request)
    let enhanced = try #require(definition["enhancedMode"] as? [String: Any])
    #expect(enhanced["enabled"] as? Bool == true)
    #expect(enhanced["model"] as? String == "MAI-Transcribe-2")
    #expect((enhanced["modelOptions"] as? [String: Any])?["transcribeStyle"] as? String == "clean")
    #expect((definition["phraseList"] as? [String: Any])?["phrases"] as? [String] == ["Kubernetes", "XX"])
    // German and English are found by the model: no language is fixed.
    #expect(definition["locales"] == nil)
    #expect(Set(definition.keys) == ["enhancedMode", "phraseList"])
}

@Test func theFillerSwitchBecomesMAIsTranscribeStyle() throws {
    func style(_ removes: Bool) throws -> String? {
        var settings = Transcriber.Settings(provider: .microsoft)
        settings.removesFillers = removes
        let request = Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k")
        let enhanced = try definition(of: request)["enhancedMode"] as? [String: Any]
        return (enhanced?["modelOptions"] as? [String: Any])?["transcribeStyle"] as? String
    }
    #expect(try style(true) == "clean")
    #expect(try style(false) == "verbatim")
}

@Test func plainAzureSpeechHasNoEnhancedModeAndAnEmptyWordListSendsNoPhraseList() throws {
    let settings = Transcriber.Settings(provider: .microsoft, model: "azure-speech")
    let request = Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k")
    let part = try #require(try parts(of: request)["definition"])
    #expect(part.text == "{}")
}

@Test func aModelTypedInByHandIsSentAsTypedAndOnlyMAI2GetsTheStyle() throws {
    func sent(_ model: String) throws -> [String: Any] {
        let request = Transcriber(settings: Transcriber.Settings(provider: .microsoft, model: model)).makeRequest(wav: wav, apiKey: "k")
        return try definition(of: request)
    }
    let future = try #require(try sent("MAI-Transcribe-3")["enhancedMode"] as? [String: Any])
    #expect(future["model"] as? String == "MAI-Transcribe-3" && future["modelOptions"] == nil)
    let upper = try #require(try sent("MAI-TRANSCRIBE-2")["enhancedMode"] as? [String: Any])
    #expect(upper["model"] as? String == "MAI-Transcribe-2" && upper["modelOptions"] != nil)
}

@Test func anOwnAddressIsWhereMicrosoftsRequestGoes() {
    let settings = Transcriber.Settings(provider: .microsoft, microsoftRegion: "eastus",
                                        microsoftEndpoint: "https://satz-speech.cognitiveservices.azure.com")
    let request = Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k")
    #expect(request.url?.absoluteString
            == "https://satz-speech.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
}

// MARK: - Microsoft: the answer

@Test func microsoftsAnswerIsReadFromTheCombinedPhrases() {
    let documented = #"""
    {"durationMilliseconds": 4200, "combinedPhrases": [{"text": "Hallo Welt, das ist ein Test."}],
     "phrases": [{"offsetMilliseconds": 0, "durationMilliseconds": 4200, "text": "Hallo Welt, das ist ein Test.", "locale": "de-DE", "confidence": 0.93}]}
    """#
    #expect(MicrosoftSpeech.text(in: Data(documented.utf8)) == "Hallo Welt, das ist ein Test.")
    // One per channel: joined.
    #expect(MicrosoftSpeech.text(in: Data(#"{"combinedPhrases": [{"channel": 0, "text": "eins"}, {"channel": 1, "text": " zwei "}]}"#.utf8)) == "eins zwei")
    // Silence: the list, with nothing in it. An empty answer, not a broken one.
    #expect(MicrosoftSpeech.text(in: Data(#"{"durationMilliseconds": 900, "combinedPhrases": [{"text": ""}], "phrases": []}"#.utf8)) == "")
    #expect(MicrosoftSpeech.text(in: Data(#"{"durationMilliseconds": 900, "combinedPhrases": [], "phrases": []}"#.utf8)) == "")
    // Without the combined list, the phrases.
    #expect(MicrosoftSpeech.text(in: Data(#"{"phrases": [{"text": "a"}, {"text": "b"}]}"#.utf8)) == "a b")
    #expect(MicrosoftSpeech.text(in: Data(#"{"something": "else"}"#.utf8)) == nil)
    #expect(MicrosoftSpeech.text(in: Data("not json".utf8)) == nil)
}

@Test func microsoftsErrorsBecomeSomethingAUserCanActOn() {
    let azure = Transcriber.Format.azureSpeech
    let wrongKey = Data(#"{"error": {"code": "401", "message": "Access denied due to invalid subscription key or wrong API endpoint."}}"#.utf8)
    #expect(Transcriber.failure(status: 401, body: wrongKey, format: azure) == .keyOrRegionWrong)
    #expect(Transcriber.failure(status: 403, body: Data(), format: azure) == .keyOrRegionWrong)
    #expect(Transcriber.failure(status: 429, body: Data(), format: azure) == .rateLimited)
    #expect(Transcriber.failure(status: 413, body: Data(), format: azure) == .tooLarge)
    let tooLong = Data(#"{"code": "InvalidRequest", "message": "The audio file is too long."}"#.utf8)
    #expect(Transcriber.failure(status: 400, body: tooLong, format: azure) == .tooLarge)
    // Anything else keeps its status and Azure's own words, from either shape.
    #expect(Transcriber.failure(status: 400, body: Data(#"{"code": "InvalidRequest", "message": "Invalid locale."}"#.utf8), format: azure)
            == .server(status: 400, message: "Invalid locale."))
    #expect(Transcriber.failure(status: 500, body: Data(), format: azure) == .server(status: 500, message: nil))
    // The other providers still say "key rejected" for 401.
    #expect(Transcriber.failure(status: 401, body: Data()) == .unauthorized)
}

@Test func theMessageForAWrongKeyOrRegionIsInBothLanguagesWithoutAnEmDash() {
    // Either, depending on the language the app is in just now.
    #expect(["Schlüssel oder Region falsch.", "Key or region wrong."].contains(Transcriber.Failure.keyOrRegionWrong.message))
    #expect(!Transcriber.Failure.keyOrRegionWrong.message.contains("\u{2014}"))
    // Fixing the key or the region and sending again can work.
    #expect(Transcriber.Failure.keyOrRegionWrong.retryHelps)
}

// MARK: - Microsoft: against the stand-in

@Suite(.serialized)
struct MicrosoftStandInTests {

    @Test func theWholeCallReachesTheServerAsDocumentedAndTheAnswerIsRead() async throws {
        let server = try await StandInServer.start([
            .init(body: #"{"durationMilliseconds": 3000, "combinedPhrases": [{"text": "Das ist ein Test."}], "phrases": []}"#),
        ])
        defer { server.stop() }
        var settings = Transcriber.Settings(provider: .microsoft)
        settings.vocabulary = ["satz"]
        let text = try await transcriber(settings, against: server).transcribe(wav: wav, apiKey: "azure-secret")

        #expect(text == "Das ist ein Test.")
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.target == "/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
        #expect(request.headers["ocp-apim-subscription-key"] == "azure-secret")
        #expect(request.headers["authorization"] == nil)
        #expect(request.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        let sent = try #require(MultipartParts(body: request.body, contentType: request.headers["content-type"]))
        #expect(sent["audio"]?.data == wav)
        let definition = try #require(sent["definition"])
        let enhanced = try json(definition.data)["enhancedMode"] as? [String: Any]
        #expect(enhanced?["model"] as? String == "MAI-Transcribe-2")
    }

    @Test func aWrongKeyOrRegionIsNamedAndNotRetried() async throws {
        let server = try await StandInServer.start([
            .init(status: 401, body: #"{"error": {"code": "401", "message": "Access denied due to invalid subscription key or wrong API endpoint."}}"#),
            .init(body: #"{"combinedPhrases": [{"text": "nein"}]}"#),
        ])
        defer { server.stop() }
        await #expect(throws: Transcriber.Failure.keyOrRegionWrong) {
            try await transcriber(Transcriber.Settings(provider: .microsoft), against: server).transcribe(wav: wav, apiKey: "k")
        }
        #expect(server.requests.count == 1)
    }

    @Test func aThrottledRequestIsTriedAgainLikeEveryOtherProviders() async throws {
        let server = try await StandInServer.start([
            .init(status: 429, headers: ["Retry-After": "0"], body: #"{"error": {"message": "Too many requests"}}"#),
            .init(body: #"{"combinedPhrases": [{"text": "geschafft"}]}"#),
        ])
        defer { server.stop() }
        let text = try await transcriber(Transcriber.Settings(provider: .microsoft), against: server).transcribe(wav: wav, apiKey: "k")
        #expect(text == "geschafft")
        #expect(server.requests.count == 2)
    }

    @Test func aRecordingMicrosoftRefusesAsTooLargeOffersNoRetry() async throws {
        let server = try await StandInServer.start([.init(status: 413, body: "")])
        defer { server.stop() }
        do {
            _ = try await transcriber(Transcriber.Settings(provider: .microsoft), against: server).transcribe(wav: wav, apiKey: "k")
            Issue.record("answered")
        } catch let failure as Transcriber.Failure {
            #expect(failure == .tooLarge && !failure.retryHelps)
        }
    }

    @Test func silenceComesBackAsAnEmptyAnswer() async throws {
        let server = try await StandInServer.start([.init(body: #"{"durationMilliseconds": 800, "combinedPhrases": [], "phrases": []}"#)])
        defer { server.stop() }
        let text = try await transcriber(Transcriber.Settings(provider: .microsoft), against: server).transcribe(wav: wav, apiKey: "k")
        #expect(text == "")
    }

    @Test func anAnswerThatIsNotMicrosoftsIsUnreadable() async throws {
        let server = try await StandInServer.start([.init(body: #"{"text": "this is OpenAI's shape"}"#)])
        defer { server.stop() }
        await #expect(throws: Transcriber.Failure.unreadableResponse) {
            try await transcriber(Transcriber.Settings(provider: .microsoft), against: server).transcribe(wav: wav, apiKey: "k")
        }
    }
}

// MARK: - Google: the request

@Test func googlesRequestIsTheDocumentedInteractionsCall() throws {
    var settings = Transcriber.Settings(provider: .google)
    settings.vocabulary = ["Kubernetes", "XX"]
    let request = Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "AIza-secret")

    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-secret")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    // Not `?key=`: the key is in the header and never in an address that gets logged.
    #expect(request.url?.absoluteString.contains("AIza-secret") == false)

    let httpBody = try #require(request.httpBody)
    let body = try json(httpBody)
    // `store: false` keeps Google from keeping the recording as an interaction.
    #expect(Set(body.keys) == ["model", "input", "generation_config", "store"])
    #expect(body["model"] as? String == "gemini-3.5-transcribe")
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input[0]["type"] as? String == "audio")
    #expect(input[0]["mime_type"] as? String == "audio/wav")
    #expect(input[0]["data"] as? String == wav.base64EncodedString())
    let config = try transcriptionConfig(of: request)
    // An empty list is auto-detection.
    #expect((config["language_codes"] as? [Any])?.isEmpty == true)
    #expect(config["custom_vocabulary"] as? [String] == ["Kubernetes", "XX"])
    #expect(config["mode"] as? String == "smart")
}

@Test func smartModeFollowsTheFillerSwitchAndAnEmptyWordListIsLeftOut() throws {
    func config(removes: Bool, words: [String]) throws -> [String: Any] {
        var settings = Transcriber.Settings(provider: .google)
        settings.removesFillers = removes
        settings.vocabulary = words
        return try transcriptionConfig(of: Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k"))
    }
    #expect(try config(removes: true, words: [])["mode"] as? String == "smart")
    // Verbatim is what is left when the mode is not named.
    #expect(try config(removes: false, words: [])["mode"] == nil)
    #expect(try config(removes: false, words: [])["custom_vocabulary"] == nil)
    #expect(try config(removes: false, words: ["a"])["custom_vocabulary"] as? [String] == ["a"])
}

@Test func theVocabularyIsCutAtAThousandTerms() throws {
    var settings = Transcriber.Settings(provider: .google)
    settings.vocabulary = (0 ..< 1_200).map { "word\($0)" }
    let request = Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k")
    let words = try #require(try transcriptionConfig(of: request)["custom_vocabulary"] as? [String])
    #expect(words.count == 1_000 && words.first == "word0" && words.last == "word999")
}

@Test func theModelIdIsSentWithoutGoogleModelsPrefix() throws {
    let settings = Transcriber.Settings(provider: .google, model: "models/gemini-3.5-transcribe")
    let httpBody = try #require(Transcriber(settings: settings).makeRequest(wav: wav, apiKey: "k").httpBody)
    #expect(try json(httpBody)["model"] as? String == "gemini-3.5-transcribe")
}

// MARK: - Google: the answer

@Test func googlesAnswerIsReadFromTheStepsAndFromTheOtherShapesItMightUse() {
    let text = { (json: String) in GeminiTranscribe.text(in: Data(json.utf8)) }
    // The documented one.
    #expect(text(#"{"id": "i1", "status": "completed", "steps": [{"type": "model_output", "content": [{"type": "text", "text": "Hallo Welt."}]}]}"#) == "Hallo Welt.")
    // Several items and steps, and the ones that are not words are skipped.
    #expect(text(#"{"steps": [{"type": "thought", "content": [{"type": "text", "text": "thinking"}]}, {"type": "model_output", "content": [{"type": "text", "text": "Eins."}, {"type": "text", "text": " Zwei."}]}]}"#) == "Eins. Zwei.")
    // The SDKs' flat field.
    #expect(text(#"{"output_text": "Direkt."}"#) == "Direkt.")
    // The interactions API's earlier name for the steps.
    #expect(text(#"{"outputs": [{"type": "text", "text": "Früher."}]}"#) == "Früher.")
    // generateContent's shape: a plain text part, or an audioTranscription one.
    #expect(text(#"{"candidates": [{"content": {"parts": [{"text": "Teil."}]}}]}"#) == "Teil.")
    #expect(text(#"{"candidates": [{"content": {"parts": [{"audioTranscription": "Als Text."}]}}]}"#) == "Als Text.")
    #expect(text(#"{"candidates": [{"content": {"parts": [{"audioTranscription": {"text": "Als Objekt.", "languageCode": "de-DE"}}]}}]}"#) == "Als Objekt.")
    // A well-formed answer without words (silence, a blocked one) is empty, not broken.
    #expect(text(#"{"steps": [{"type": "model_output", "content": []}]}"#) == "")
    #expect(text(#"{"candidates": [{"finishReason": "SAFETY"}]}"#) == "")
    #expect(text(#"{"candidates": []}"#) == "")
    // Neither is an answer.
    #expect(text(#"{"error": {"message": "x"}}"#) == nil)
    #expect(text("not json") == nil)
}

@Test func googlesErrorsBecomeSomethingAUserCanActOn() {
    let gemini = Transcriber.Format.gemini
    let badKey = Data(#"{"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT", "details": [{"reason": "API_KEY_INVALID"}]}}"#.utf8)
    #expect(Transcriber.failure(status: 400, body: badKey, format: gemini) == .unauthorized)
    #expect(Transcriber.failure(status: 403, body: Data(#"{"error": {"status": "PERMISSION_DENIED"}}"#.utf8), format: gemini) == .unauthorized)
    #expect(Transcriber.failure(status: 429, body: Data(#"{"error": {"status": "RESOURCE_EXHAUSTED"}}"#.utf8), format: gemini) == .rateLimited)
    #expect(Transcriber.failure(status: 413, body: Data(), format: gemini) == .tooLarge)
    let tooBig = Data(#"{"error": {"code": 400, "message": "Request payload size exceeds the limit: 20971520 bytes.", "status": "INVALID_ARGUMENT"}}"#.utf8)
    #expect(Transcriber.failure(status: 400, body: tooBig, format: gemini) == .tooLarge)
    #expect(Transcriber.failure(status: 400, body: Data(#"{"error": {"message": "Unsupported language."}}"#.utf8), format: gemini)
            == .server(status: 400, message: "Unsupported language."))
    // Google has no "key or region": that is Azure's.
    #expect(Transcriber.failure(status: 401, body: Data(), format: gemini) == .unauthorized)
}

// MARK: - Google: the size limit

@Test func aRecordingOverAboutSevenMinutesIsRefusedBeforeAnythingIsSent() {
    // 16 kHz, 16 bit, mono: 32 000 bytes a second.
    let seconds = { (s: Int) in Data(count: 44 + s * 32_000) }
    #expect(!GeminiTranscribe.isTooLarge(wav: seconds(60), vocabulary: []))
    #expect(!GeminiTranscribe.isTooLarge(wav: seconds(420), vocabulary: []))
    #expect(!GeminiTranscribe.isTooLarge(wav: seconds(460), vocabulary: ["Kubernetes"]))
    // 20 MB of request is 15 MB of audio, 468 s: the limit sits just above seven and a half minutes.
    #expect(GeminiTranscribe.isTooLarge(wav: seconds(470), vocabulary: []))
    #expect(GeminiTranscribe.isTooLarge(wav: seconds(600), vocabulary: []))
}

@Test func theLimitIsCountedWithTheVocabularyAndBase64() {
    let nearly = Data(count: 14_990_000)
    #expect(!GeminiTranscribe.isTooLarge(wav: nearly, vocabulary: []))
    #expect(GeminiTranscribe.isTooLarge(wav: nearly, vocabulary: (0 ..< 1_000).map { String(repeating: "x", count: 30) + "\($0)" }))
}

@Suite(.serialized)
struct GoogleStandInTests {

    @Test func theWholeCallReachesTheServerAsDocumentedAndTheAnswerIsRead() async throws {
        let server = try await StandInServer.start([
            .init(body: #"{"steps": [{"type": "model_output", "content": [{"type": "text", "text": "Das ist ein Test."}]}]}"#),
        ])
        defer { server.stop() }
        var settings = Transcriber.Settings(provider: .google)
        settings.vocabulary = ["satz"]
        let text = try await transcriber(settings, against: server).transcribe(wav: wav, apiKey: "AIza-secret")

        #expect(text == "Das ist ein Test.")
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.target == "/interactions")
        #expect(request.headers["x-goog-api-key"] == "AIza-secret")
        #expect(request.headers["authorization"] == nil)
        #expect(request.headers["content-type"] == "application/json")
        let body = try json(request.body)
        #expect(body["model"] as? String == "gemini-3.5-transcribe")
        #expect(((body["input"] as? [[String: Any]])?.first?["data"] as? String) == wav.base64EncodedString())
        let config = (body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
        #expect(config?["mode"] as? String == "smart" && config?["custom_vocabulary"] as? [String] == ["satz"])
    }

    @Test func aRecordingThatDoesNotFitFailsAtOnceWithoutAnyRequest() async throws {
        let server = try await StandInServer.start([.init(body: #"{"output_text": "never"}"#)])
        defer { server.stop() }
        let eightMinutes = Data(count: 44 + 480 * 32_000)
        do {
            _ = try await transcriber(Transcriber.Settings(provider: .google), against: server).transcribe(wav: eightMinutes, apiKey: "k")
            Issue.record("sent")
        } catch let failure as Transcriber.Failure {
            #expect(failure == .tooLarge && !failure.retryHelps)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func aRecordingJustUnderTheLimitIsSent() async throws {
        let server = try await StandInServer.start([.init(body: #"{"output_text": "lang"}"#)])
        defer { server.stop() }
        let sevenMinutes = Data(count: 44 + 420 * 32_000)
        let text = try await transcriber(Transcriber.Settings(provider: .google), against: server).transcribe(wav: sevenMinutes, apiKey: "k")
        #expect(text == "lang")
        let request = try #require(server.requests.first)
        #expect(request.body.count < GeminiTranscribe.requestLimit)
    }

    @Test func aRejectedKeyIsNamedAndNotRetried() async throws {
        let server = try await StandInServer.start([
            .init(status: 400, body: #"{"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT"}}"#),
            .init(body: #"{"output_text": "nein"}"#),
        ])
        defer { server.stop() }
        await #expect(throws: Transcriber.Failure.unauthorized) {
            try await transcriber(Transcriber.Settings(provider: .google), against: server).transcribe(wav: wav, apiKey: "bad")
        }
        #expect(server.requests.count == 1)
    }

    @Test func aThrottledRequestIsTriedAgain() async throws {
        let server = try await StandInServer.start([
            .init(status: 429, headers: ["Retry-After": "0"], body: #"{"error": {"status": "RESOURCE_EXHAUSTED"}}"#),
            .init(body: #"{"candidates": [{"content": {"parts": [{"text": "geschafft"}]}}]}"#),
        ])
        defer { server.stop() }
        let text = try await transcriber(Transcriber.Settings(provider: .google), against: server).transcribe(wav: wav, apiKey: "k")
        #expect(text == "geschafft")
        #expect(server.requests.count == 2)
    }

    @Test func aMissingKeyFailsBeforeAnythingIsSent() async throws {
        let server = try await StandInServer.start([])
        defer { server.stop() }
        await #expect(throws: Transcriber.Failure.noKey) {
            try await transcriber(Transcriber.Settings(provider: .google), against: server).transcribe(wav: wav, apiKey: "")
        }
        #expect(server.requests.isEmpty)
    }
}
