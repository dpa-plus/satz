import Foundation
import Testing
import SatzKit
@testable import SatzMac

// Microsoft's region and own address, and what the app hands the transcriber
// for the two new providers. In memory, or in a private defaults suite: never
// the user's own preferences.

@MainActor
private func isolated(_ body: (UserDefaults) -> Void) {
    let name = "plus.dpa.satz.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    // Preferences made from stored values set the app-wide language and colours.
    let language = Language.current, theme = AppTheme.current
    defer {
        defaults.removePersistentDomain(forName: name)
        Language.current = language
        AppTheme.current = theme
    }
    body(defaults)
}

@Suite(.serialized) @MainActor
struct ProviderPreferencesTests {

    @Test func microsoftStartsInNorthEuropeWithoutAnAddress() {
        let preferences = Preferences(defaults: nil)
        #expect(preferences.microsoftRegion == "northeurope" && preferences.microsoftEndpoint.isEmpty)
    }

    @Test func theRegionAndTheAddressAreKeptBetweenRuns() {
        isolated { defaults in
            let first = Preferences(defaults: defaults)
            first.microsoftRegion = "westus2"
            first.microsoftEndpoint = "https://satz-speech.cognitiveservices.azure.com"
            let again = Preferences(defaults: defaults)
            #expect(again.microsoftRegion == "westus2")
            #expect(again.microsoftEndpoint == "https://satz-speech.cognitiveservices.azure.com")
        }
    }

    @Test func eachProviderKeepsItsOwnModel() {
        let preferences = Preferences(defaults: nil)
        #expect(preferences.model(for: .microsoft) == "mai-transcribe-2")
        #expect(preferences.model(for: .google) == "gemini-3.5-transcribe")
        preferences.setModel("azure-speech", for: .microsoft)
        #expect(preferences.model(for: .microsoft) == "azure-speech")
        #expect(preferences.model(for: .google) == "gemini-3.5-transcribe" && preferences.model(for: .openRouter) == "microsoft/mai-transcribe-2")
    }

    @Test func theTranscriberIsGivenTheRegionOrTheAddressOfTheProviderInUse() {
        let preferences = Preferences(defaults: nil)
        preferences.provider = .microsoft
        preferences.microsoftRegion = "centralindia"
        #expect(preferences.transcriberSettings.format == .azureSpeech)
        #expect(preferences.transcriberSettings.baseURL.absoluteString == "https://centralindia.api.cognitive.microsoft.com")
        preferences.microsoftEndpoint = "https://mine.cognitiveservices.azure.com/"
        #expect(preferences.transcriberSettings.baseURL.absoluteString == "https://mine.cognitiveservices.azure.com")
        preferences.provider = .google
        #expect(preferences.transcriberSettings.format == .gemini)
        #expect(preferences.transcriberSettings.baseURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta")
        // A region or address set for Microsoft never leaks into another provider.
        preferences.provider = .openRouter
        #expect(preferences.transcriberSettings.baseURL.host == "openrouter.ai")
    }

    @Test func theFillerSwitchAndTheWordListReachBothProviders() {
        let preferences = Preferences(defaults: nil)
        preferences.words = ["Kubernetes"]
        preferences.removesFillers = false
        for provider in [Provider.microsoft, .google] {
            preferences.provider = provider
            #expect(preferences.transcriberSettings.removesFillers == false)
            #expect(preferences.transcriberSettings.vocabulary.contains("Kubernetes"))
        }
    }

    @Test func anAddressThatCannotWorkKeepsMicrosoftFromRecordingAndNamesWhatIsMissing() {
        let preferences = Preferences(defaults: nil)
        preferences.provider = .microsoft
        #expect(!preferences.isEndpointMissing)
        preferences.microsoftEndpoint = "http://insecure.example.org"
        #expect(preferences.isEndpointMissing)
        #expect(preferences.missing(.microsoft, hasKey: true) == [.addressRefused])
        #expect(preferences.missing(.microsoft, hasKey: false) == [.key, .addressRefused])
        preferences.microsoftEndpoint = ""
        #expect(!preferences.isEndpointMissing && preferences.missing(.microsoft, hasKey: true).isEmpty)
        // Google has nothing but its key to miss.
        preferences.provider = .google
        #expect(!preferences.isEndpointMissing && preferences.missing(.google, hasKey: true).isEmpty)
    }

    @Test func theProviderMenuMarksTheOneInUse() {
        #expect(ProviderMenu.title(.microsoft, inUse: .microsoft) == "Microsoft · in Benutzung"
                || ProviderMenu.title(.microsoft, inUse: .microsoft) == "Microsoft · in use")
        #expect(ProviderMenu.title(.google, inUse: .microsoft) == "Google")
        // Setup has none in use yet.
        #expect(ProviderMenu.title(.google, inUse: nil) == "Google")
    }

    @Test func aFailedRequestIsSaidInTwoOrThreeWordsForTheNewKeyError() {
        #expect(["Schlüssel oder Region falsch", "Key or region wrong"].contains(Transcriber.Failure.keyOrRegionWrong.short))
    }

    @Test func aRefusedRedirectIsSaidOnTheCardAsTheAddressAndExplainedInTheLog() {
        // The card shows `short`; the log gets the explanation (`message`, which
        // Session writes with "transcription failed").
        let failure = Transcriber.Failure.redirected
        #expect(["Adresse leitet um", "Address redirects"].contains(failure.short))
        #expect(failure.short != failure.message)
        #expect(failure.message.count > failure.short.count * 2)
        #expect(!failure.short.contains("\u{2014}") && !failure.message.contains("\u{2014}"))
        // Not the generic "Provider error (307)" it used to be.
        #expect(!failure.short.contains("307"))
    }
}
