import Foundation
import Testing
@testable import SatzKit

// What the Mac app's Settings, Setup and launch share, kept in SatzKit so
// these tests can reach it. Language is always passed in: none of these
// touches the global one, which other tests set while they run.

// MARK: - Test mode: --flag=value

@Test func theEqualsSpellingOfTestFlagsIsReadLikeTheTwoWordOne() {
    // The spelling most people type. It used to parse as a normal launch:
    // a second shortcut listener next to the real satz, other copies quit,
    // and the models folder writable.
    #expect(LaunchMode.parse(["satz", "--dev-control=/s/state.json"]) == .test(stateFile: "/s/state.json", modelsFolder: nil))
    #expect(LaunchMode.parse(["satz", "--dev-control=/s/state.json", "--models-dir=/m"])
            == .test(stateFile: "/s/state.json", modelsFolder: "/m"))
    // Mixed: the folder used to be dropped without a word.
    #expect(LaunchMode.parse(["satz", "--dev-control", "/s/state.json", "--models-dir=/m"])
            == .test(stateFile: "/s/state.json", modelsFolder: "/m"))
    #expect(LaunchMode.parse(["satz", "--dev-control=/s/state.json", "--models-dir", "/m"])
            == .test(stateFile: "/s/state.json", modelsFolder: "/m"))
    #expect(LaunchMode.parse(["satz", "--dev-control=/s/state.json", "--models-dir=/m"]).canChangeModels)
    // Only the first "=" splits: a path may hold more of them.
    #expect(LaunchMode.parse(["satz", "--dev-control=/s/a=b.json"]) == .test(stateFile: "/s/a=b.json", modelsFolder: nil))
}

@Test func anEqualsFlagWithoutAValueIsRefusedNotIgnored() {
    for broken in [["satz", "--dev-control="], ["satz", "--dev-control=/s/state.json", "--models-dir="],
                   ["satz", "--models-dir=/m"], ["satz", "--dev-control=/s/state.json", "--test-audio="]] {
        guard case .invalid = LaunchMode.parse(broken) else { Issue.record("accepted \(broken)"); continue }
    }
}

@Test func clipsAndMusicFlagsNeedATestCopy() {
    // `--test-audio x.wav` alone used to be the user's own satz recording from
    // a clip; `--test-media` alone would pause their music from a test.
    for alone in [["satz", "--test-audio", "/a.wav"], ["satz", "--test-audio=/a.wav"], ["satz", "--test-media"]] {
        guard case .invalid = LaunchMode.parse(alone) else { Issue.record("ran \(alone) as the real satz"); continue }
    }
    #expect(LaunchMode.parse(["satz", "--test-audio=/a.wav", "--dev-control=/s/state.json", "--test-media"])
            == .test(stateFile: "/s/state.json", modelsFolder: nil))
    #expect(LaunchMode.parse(["satz", "--test-audio", "/a.wav:/b.wav", "--dev-control", "/s/state.json"])
            == .test(stateFile: "/s/state.json", modelsFolder: nil))
    guard case .invalid = LaunchMode.parse(["satz", "--dev-control", "/s/state.json", "--test-audio"]) else {
        Issue.record("accepted --test-audio without a file"); return
    }
    guard case .invalid = LaunchMode.parse(["satz", "--dev-control", "/s/state.json", "--test-media=yes"]) else {
        Issue.record("accepted a value for the --test-media switch"); return
    }
}

@Test func aSingleDashTestFlagIsATypoNotNothing() {
    // `-models-dir /m` was skipped, and the run went on without its folder.
    for typo in [["satz", "--dev-control", "/s/state.json", "-models-dir", "/m"], ["satz", "-dev-control=/s/state.json"],
                 ["satz", "-test-audio", "/a.wav"]] {
        guard case .invalid = LaunchMode.parse(typo) else { Issue.record("accepted \(typo)"); continue }
    }
    // Defaults overrides such as `-provider local` are not ours.
    #expect(LaunchMode.parse(["satz", "-provider", "local"]) == .normal)
    #expect(LaunchMode.parse(["satz", "--dev-control", "/s/state.json", "-provider", "local"])
            == .test(stateFile: "/s/state.json", modelsFolder: nil))
}

@Test func theAppReadsItsOwnFlagsInBothSpellings() {
    #expect(LaunchMode.argument("--snapshot", in: ["satz", "--snapshot", "/tmp/s"]) == "/tmp/s")
    #expect(LaunchMode.argument("--snapshot", in: ["satz", "--snapshot=/tmp/s"]) == "/tmp/s")
    #expect(LaunchMode.argument("--snapshot", in: ["satz"]) == nil)
    #expect(LaunchMode.argument("--snapshot", in: ["satz", "--snapshot"]) == nil)
    #expect(LaunchMode.argument("--snapshot", in: ["satz", "--snapshot", "--hero"]) == nil)
    #expect(LaunchMode.argument("--snapshot", in: ["satz", "--snapshot="]) == nil)
}

// MARK: - What a provider needs

@Test func anAddressAloneDoesNotMakeAnOwnEndpointUsable() {
    // Codex MR-4: Settings offered "Eigener benutzen" with only an address,
    // while the setup refused the same state.
    let urlOnly = ProviderReadiness.missing(.custom, hasKey: false, customBaseURL: "https://example.invalid/v1", model: "")
    #expect(urlOnly == [.key, .model])
    let keyAndAddress = ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: "https://example.invalid/v1", model: "  ")
    #expect(keyAndAddress == [.model])
    #expect(ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: "", model: "whisper-1") == [.address])
    #expect(ProviderReadiness.missing(.custom, hasKey: false, customBaseURL: "", model: "") == [.key, .address, .model])
    #expect(ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: "http://localhost:8080/v1", model: "whisper-1").isEmpty)
}

@Test func otherProvidersNeedOnlyTheirKeyOrTheirModel() {
    // They have an address and a default model of their own.
    for provider in [Provider.openAI, .openRouter, .groq] {
        #expect(ProviderReadiness.missing(provider, hasKey: false, customBaseURL: "", model: "") == [.key])
        #expect(ProviderReadiness.missing(provider, hasKey: true, customBaseURL: "", model: "").isEmpty)
    }
    // For Lokal "hasKey" says the chosen model is on this Mac.
    #expect(ProviderReadiness.missing(.local, hasKey: false, customBaseURL: "https://x/v1", model: "x") == [.localModel])
    #expect(ProviderReadiness.missing(.local, hasKey: true, customBaseURL: "", model: "").isEmpty)
}

@Test func theUsableAddressIsOneWithAHost() {
    #expect(ProviderReadiness.hasUsableAddress("https://example.invalid/v1"))
    #expect(ProviderReadiness.hasUsableAddress("  http://localhost:8080/v1 "))
    #expect(!ProviderReadiness.hasUsableAddress(""))
    #expect(!ProviderReadiness.hasUsableAddress("   "))
    #expect(!ProviderReadiness.hasUsableAddress("not an address"))
    #expect(ProviderReadiness.hasModel("whisper-1"))
    #expect(!ProviderReadiness.hasModel(" \t"))
}

@Test func theMessageNamesEverythingThatIsMissing() {
    let de = Language.german, en = Language.english
    #expect(ProviderReadiness.message([], in: de) == nil)
    #expect(ProviderReadiness.message([.key], in: de) == "Erst den Schlüssel eintragen")
    #expect(ProviderReadiness.message([.address], in: de) == "Erst die Adresse eintragen")
    #expect(ProviderReadiness.message([.model], in: de) == "Erst das Modell eintragen")
    #expect(ProviderReadiness.message([.address, .model], in: de) == "Erst Adresse und Modell eintragen")
    #expect(ProviderReadiness.message([.key, .address, .model], in: de) == "Erst Schlüssel, Adresse und Modell eintragen")
    #expect(ProviderReadiness.message([.localModel], in: de) == "Erst ein Modell laden")
    #expect(ProviderReadiness.message([.key], in: en) == "Enter the key first")
    #expect(ProviderReadiness.message([.address], in: en) == "Enter the address first")
    #expect(ProviderReadiness.message([.model], in: en) == "Enter the model first")
    #expect(ProviderReadiness.message([.address, .model], in: en) == "Enter the address and model first")
    #expect(ProviderReadiness.message([.key, .address, .model], in: en) == "Enter the key, address and model first")
    #expect(ProviderReadiness.message([.localModel], in: en) == "Download a model first")
}

// MARK: - The switch under the provider menu

@Test func theSwitchRowIsWordedAsOnWindowsAndLinux() {
    // The same sentences as desktop/test/browse.test.ts, but for the quote
    // marks: the Mac's English uses typographic ones.
    #expect(SwitchWording.goesTo(.openRouter, in: .german) == "Diktate gehen an OpenRouter.")
    #expect(SwitchWording.goesTo(.openRouter, in: .english) == "Dictation goes to OpenRouter.")
    #expect(SwitchWording.goesTo(.local, in: .german) == "Diktate gehen an „Lokal“.")
    #expect(SwitchWording.goesTo(.custom, in: .german) == "Diktate gehen an „Eigener“.")
    #expect(SwitchWording.goesTo(.custom, in: .english) == "Dictation goes to “Custom”.")
    #expect(SwitchWording.goesTo(.local, in: .english) == "Dictation goes to “Local”.")
    #expect(SwitchWording.button(.local, in: .german) == "Lokal benutzen")
    #expect(SwitchWording.button(.local, in: .english) == "Use Local")
    // Accusative: "Eigener benutzen" was ungrammatical.
    #expect(SwitchWording.button(.custom, in: .german) == "Eigenen benutzen")
    #expect(SwitchWording.button(.custom, in: .english) == "Use Custom")
    #expect(SwitchWording.button(.openAI, in: .german) == "OpenAI benutzen")
    #expect(SwitchWording.button(.groq, in: .english) == "Use Groq")
}

@Test func noWordingOfSettingsHasAnEmDash() {
    for provider in Provider.allCases {
        for language in Language.allCases {
            #expect(!SwitchWording.goesTo(provider, in: language).contains("—"))
            #expect(!SwitchWording.button(provider, in: language).contains("—"))
        }
    }
    let needs: [[ProviderReadiness.Need]] = [[.key], [.address], [.model], [.localModel], [.key, .address, .model]]
    for list in needs {
        for language in Language.allCases {
            #expect(ProviderReadiness.message(list, in: language)?.contains("—") == false)
        }
    }
}

// MARK: - Undo

@Test func undoDoesNotBringBackAWordThatWasAddedAgain() {
    // Codex MR-8: remove Kubernetes, add it again inside the six seconds,
    // press Undo: it stood twice, and the list used the word as the row id.
    #expect(Restoring.word("Kubernetes", at: 0, in: ["Kubernetes", "Figma"]) == ["Kubernetes", "Figma"])
    // Add refuses a word in another case; so does Undo.
    #expect(Restoring.word("Kubernetes", at: 0, in: ["kubernetes"]) == ["kubernetes"])
    // Nothing in the way: back at its place.
    #expect(Restoring.word("Figma", at: 1, in: ["Kubernetes", "Grafana"]) == ["Kubernetes", "Figma", "Grafana"])
    // The list may have shrunk meanwhile.
    #expect(Restoring.word("Figma", at: 7, in: ["Kubernetes"]) == ["Kubernetes", "Figma"])
    #expect(Restoring.word("Figma", at: -1, in: ["Kubernetes"]) == ["Figma", "Kubernetes"])
    #expect(Restoring.containsWord("FIGMA", in: ["Figma"]))
    #expect(!Restoring.containsWord("Figma", in: []))
}

@Test func undoKeepsTheReplacementTypedForThePhraseMeanwhile() {
    // Codex MR-3: XX -> OLD removed, XX -> NEW added, Undo. Both stayed, OLD
    // first, and the first match wins: OLD replaced what the user just typed.
    let old = Replacement(spoken: "XX", written: "OLD")
    let new = Replacement(spoken: "XX", written: "NEW")
    let after = Restoring.rule(old, at: 0, in: [new])
    #expect(after == [new])
    #expect(Replacements.apply(after, to: "XX") == "NEW")
    // The phrase in another case is the same phrase, as in Add.
    #expect(Restoring.rule(old, at: 0, in: [Replacement(spoken: "xx", written: "NEW")]).count == 1)
    // A rule switched off still holds its phrase.
    #expect(Restoring.rule(old, at: 0, in: [Replacement(spoken: "XX", written: "NEW", isOn: false)]).count == 1)
    #expect(Restoring.index(ofPhrase: "xX", in: [new]) == 0)
    #expect(Restoring.index(ofPhrase: "YY", in: [new]) == nil)
}

@Test func undoStillBringsBackARemovedReplacement() {
    let first = Replacement(spoken: "Klammer auf", written: "(")
    let second = Replacement(spoken: "Klammer zu", written: ")")
    let third = Replacement(spoken: "neue Zeile", written: "\n")
    // Removed from the middle, back in the middle.
    let rules = Restoring.rule(second, at: 1, in: [first, third])
    #expect(rules.map(\.spoken) == ["Klammer auf", "Klammer zu", "neue Zeile"])
    #expect(rules[1].id == second.id)
    #expect(Restoring.rule(second, at: 9, in: [first]).map(\.spoken) == ["Klammer auf", "Klammer zu"])
    #expect(Replacements.apply(rules, to: "Klammer auf x Klammer zu") == "(x)")
}
