import Foundation
import Testing
@testable import SatzKit

private func requestURL(_ settings: Transcriber.Settings) -> String? {
    Transcriber(settings: settings).makeRequest(wav: Data(), apiKey: "k").url?.absoluteString
}

private func body(_ settings: Transcriber.Settings) throws -> String {
    String(
        decoding: try #require(Transcriber(settings: settings).makeRequest(wav: Data(), apiKey: "k").httpBody),
        as: UTF8.self
    )
}

@Test(arguments: [
    (Provider.openAI, "https://api.openai.com/v1/audio/transcriptions", "gpt-transcribe"),
    (Provider.openRouter, "https://openrouter.ai/api/v1/audio/transcriptions", "microsoft/mai-transcribe-2"),
    (Provider.groq, "https://api.groq.com/openai/v1/audio/transcriptions", "whisper-large-v3-turbo"),
])
func eachProviderIsAskedAtItsOwnEndpoint(provider: Provider, url: String, model: String) throws {
    let settings = Transcriber.Settings(provider: provider)

    #expect(requestURL(settings) == url)
    #expect(try body(settings).contains(model))
}

@Test func aCustomProviderUsesTheURLItIsGiven() {
    let settings = Transcriber.Settings(
        provider: .custom,
        model: "whisper-1",
        customBaseURL: URL(string: "https://speech.example.com/v1")
    )

    #expect(requestURL(settings) == "https://speech.example.com/v1/audio/transcriptions")
    #expect(settings.model == "whisper-1")
}

@Test func aBuiltInProviderIgnoresACustomURL() {
    // Switching from Eigener to OpenRouter must not keep sending the audio to
    // the custom server that is still filled in.
    let settings = Transcriber.Settings(
        provider: .openRouter,
        customBaseURL: URL(string: "https://speech.example.com/v1")
    )

    #expect(requestURL(settings) == "https://openrouter.ai/api/v1/audio/transcriptions")
}

@Test func anEmptyModelFallsBackToTheProvidersDefault() {
    #expect(Transcriber.Settings(provider: .groq, model: "").model == "whisper-large-v3-turbo")
    #expect(Transcriber.Settings(provider: .groq, model: "   ").model == "whisper-large-v3-turbo")
    #expect(Transcriber.Settings(provider: .groq, model: "distil-whisper").model == "distil-whisper")
}

@Test func theOpenAIKeychainAccountIsUnchanged() {
    // Keys stored before providers existed were saved under "openai". Renaming
    // the account would silently lose them.
    #expect(Provider.openAI.keychainAccount == "openai")
}

@Test func everyProviderKeepsItsOwnKey() {
    let accounts = Provider.allCases.map(\.keychainAccount)
    #expect(Set(accounts).count == accounts.count)
}

@Test func eachMenuStartsWithTheProvidersDefault() {
    // The menu shows the default as the first choice; a list that left it
    // out would show an empty or "Other" choice to every new user.
    for provider in Provider.allCases where provider != .custom {
        #expect(provider.models.first?.id == provider.defaultModel)
        #expect(Set(provider.models.map(\.id)).count == provider.models.count)
    }
    #expect(Provider.custom.models.isEmpty)
}

@Test func aModelTypedInByHandHasNoMenuEntry() {
    #expect(Provider.openRouter.choice(for: "openai/whisper-1")?.name == "Whisper")
    #expect(Provider.openRouter.choice(for: "someone/new-model") == nil)
}

@Test func openRoutersLiveListBecomesTheMenu() throws {
    let listing = """
    {"data": [
      {"id": "google/gemini-3.5-transcribe", "name": "Google: Gemini 3.5 Transcribe", "pricing": {"prompt": "0.000002", "completion": "0.000012"}},
      {"id": "someone/brand-new-stt", "name": "Someone: Brand New STT", "pricing": {"prompt": "0.00005"}},
      {"id": "openai/gpt-transcribe", "name": "OpenAI: GPT Transcribe", "pricing": {"prompt": "0.000075"}},
      {"id": "microsoft/mai-transcribe-2", "name": "Microsoft AI: MAI-Transcribe 2", "pricing": {"prompt": "0.1"}},
      {"id": "other/per-hour", "name": "Other: Per Hour", "pricing": {"prompt": "0.36"}}
    ]}
    """
    let models = try ModelCatalog.parse(Data(listing.utf8), for: .openRouter)
    // A model known to fail with satz is left out; the default leads, then
    // the scored ones, then the rest by price.
    #expect(models.map(\.id) == ["microsoft/mai-transcribe-2", "openai/gpt-transcribe", "someone/brand-new-stt", "other/per-hour"])
    let new = try #require(models.first { $0.id == "someone/brand-new-stt" })
    #expect(new.name == "Brand New STT")
    #expect(new.maker == "Someone")
    #expect(abs((new.dollarsPerHour ?? 0) - 0.18) < 0.0001)   // per second, times 3600
    #expect(models.first { $0.id == "other/per-hour" }?.dollarsPerHour == 0.36)
    #expect(models.first?.errorRate == 2.0)
    #expect(models.first?.maker == "Microsoft")
}

@Test func aPricePerTokenIsNotTurnedIntoAPricePerHour() {
    #expect(ModelCatalog.listedPrice(["prompt": "0.0000025", "completion": "0.00001"]) == nil)
    #expect(ModelCatalog.listedPrice(["prompt": "0"]) == nil)
    #expect(ModelCatalog.listedPrice(nil) == nil)
}

@Test func openAIsListIsCutToItsTranscriptionModels() throws {
    let listing = """
    {"object": "list", "data": [{"id": "gpt-5"}, {"id": "gpt-transcribe"}, {"id": "whisper-1"}, {"id": "gpt-4o-transcribe-diarize"}, {"id": "gpt-realtime-transcribe"}, {"id": "tts-1"}]}
    """
    let models = try ModelCatalog.parse(Data(listing.utf8), for: .openAI)
    #expect(models.map(\.id) == ["gpt-transcribe", "whisper-1"])
}

@Test func onlyMAITranscribe2GetsTheAzureOptions() throws {
    var settings = Transcriber.Settings(provider: .openRouter, model: "microsoft/mai-transcribe-1.5", customBaseURL: nil)
    settings.vocabulary = ["Kubernetes"]
    #expect(Transcriber(settings: settings).openRouterBody(wav: Data())["provider"] == nil)
    settings = Transcriber.Settings(provider: .openRouter, model: "microsoft/mai-transcribe-2", customBaseURL: nil)
    #expect(Transcriber(settings: settings).openRouterBody(wav: Data())["provider"] != nil)
}

@Test func onlyTheLocalProviderNeedsNoKey() {
    #expect(Provider.allCases.filter { !$0.needsKey } == [.local])
}

@Test func localModelsAreFreeAndSayHowBigTheirDownloadIs() {
    #expect(Provider.local.models.allSatisfy { $0.dollarsPerHour == 0 })
    #expect(Provider.local.models.allSatisfy { $0.errorRate == nil })
    // What the files weigh, not the "632MB" in the name.
    #expect(ModelCatalog.downloadSize(of: ModelCatalog.whisperTurbo) == "646 MB")
    #expect(ModelCatalog.downloadSize(of: ModelCatalog.apple) == nil)
    #expect(ModelCatalog.downloadSize(of: "openai_whisper-small") == "486 MB")
    #expect(ModelCatalog.downloadSize(of: "openai_whisper-medium") == nil)
}

@Test func theLocalListIsNeverAskedFor() async throws {
    #expect(try await ModelCatalog.fetch(.local, key: nil).isEmpty)
}
