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
