import Foundation
import Testing
@testable import SatzKit

@Test func theWordListIsKeptOnlyWhenItCostsNoWords() {
    let plain = "Schreib mir eine Funktion. Thanks for the update, Thursday works for me."
    #expect(WordCheck.keepEveryWord(prompted: "Schreib mir eine Funktion.", plain: plain).usedPrompt == false)
    #expect(WordCheck.keepEveryWord(prompted: plain, plain: plain).usedPrompt)
    #expect(WordCheck.keepEveryWord(prompted: "Schreib mir eine Funktion. Thanks for the update Thursday works for me", plain: plain).usedPrompt)
}

@Test func aDroppedSentenceInALongDictationIsCaughtThoughMostWordsRemain() {
    let german = (1...12).map { "Punkt \($0) ist erledigt und wir machen weiter." }.joined(separator: " ")
    let plain = german + " Thanks for the update, Thursday works for me."
    // 84 of 92 words: a count would keep it.
    #expect(WordCheck.keepEveryWord(prompted: german, plain: plain).usedPrompt == false)
}

@Test func aSpellingTheListFixedKeepsThePromptedText() {
    let plain = "Wir deployen das auf Kuber Netties und schauen in Grafana nach."
    let prompted = "Wir deployen das auf Kubernetes und schauen in Grafana nach."
    #expect(WordCheck.keepEveryWord(prompted: prompted, plain: plain).usedPrompt)
}

@Test func nothingHeardStaysNothing() {
    // The prompt alone can make Whisper repeat the word list.
    #expect(WordCheck.keepEveryWord(prompted: "Klammer auf, Klammer zu.", plain: "") == ("", false))
}

@Test func silenceAndRoomToneHaveNoSpeech() {
    #expect(SpeechGate.hasSpeech([Float](repeating: 0, count: 32_000)) == false)
    let roomTone = (0 ..< 32_000).map { Float(sin(Double($0) * 0.7)) * 0.0005 }
    #expect(SpeechGate.hasSpeech(roomTone) == false)
    // A click is too short to be speech.
    var click = roomTone
    for k in 1000 ..< 1200 { click[k] = 0.5 }
    #expect(SpeechGate.hasSpeech(click) == false)
}

@Test func aLongerMadeUpPhraseNeverBeatsADroppedSentence() {
    let plain = "Schick mir die Unterlagen. Bitte die Rechnung nicht bezahlen."
    let prompted = "Schick mir die Unterlagen. Vielen Dank fürs Zuschauen und bis zum nächsten Mal."
    #expect(WordCheck.keepEveryWord(prompted: prompted, plain: plain).usedPrompt == false)
}

@Test func speechFromAQuietMicrophoneCounts() {
    // Speech-like bursts at 2 % amplitude after a quiet start.
    let quiet: [Float] = (0 ..< 48_000).map { k in
        let burst = k > 8000 && (k / 2400) % 2 == 0
        let phase = Double(k)
        return burst ? Float(sin(phase * 0.2)) * 0.004 : Float(sin(phase)) * 0.0001
    }
    #expect(SpeechGate.hasSpeech(quiet))
}

@Test func quietSpeechCounts() {
    // A tone at -35 dBFS for half a second.
    let speech = (0 ..< 8_000).map { Float(sin(Double($0) * 0.2)) * 0.025 }
    #expect(SpeechGate.hasSpeech([Float](repeating: 0, count: 8_000) + speech))
}
