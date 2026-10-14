import Foundation
import Testing
@testable import SatzKit

// Codex's bug hunt, 14.10.2026, F01: Cohere and Qwen3 lost "Ja, genau." said
// before a long pause. The steady-noise check called the whole piece a fan,
// because the phrase was under a tenth of it. The cases are shared with
// Windows and Linux (desktop/test/codexFixSteadyNoise.test.ts).

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtures = root.appendingPathComponent("Tests/Fixtures/CodexFixSteadyNoise")

private struct SteadyCase: Decodable {
    struct Noise: Decodable {
        let kind: String
        let amplitude: Double?
        let level: Double?
        let seed: UInt32?
        let hertz: Double?
        let pole: Double?
    }

    struct Clip: Decodable {
        let at: Double
        let gain: Double?
        let until: Double?
    }

    let name: String
    let seconds: Double
    let noise: Noise?
    let clip: Clip?
    let taps: [Double]?
    let steady: Bool
}

private struct SteadyTable: Decodable { let cases: [SteadyCase] }

private func steadyCases() throws -> [SteadyCase] {
    try JSONDecoder().decode(SteadyTable.self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json"))).cases
}

private func spokenPhrase() throws -> [Float] {
    try #require(WAVDecoder.decode(Data(contentsOf: fixtures.appendingPathComponent("ja-genau.wav")))).samples
}

/// Codex's generator, so the first cases are its fixtures and desktop makes the same numbers.
private func white(_ count: Int, seed: UInt32) -> [Double] {
    var x = seed
    return (0 ..< count).map { _ in
        x = 1_664_525 &* x &+ 1_013_904_223
        return Double(x) / 4_294_967_296 * 2 - 1
    }
}

private func audio(_ entry: SteadyCase, phrase: [Float], withClip: Bool = true) -> [Float] {
    let count = Int((entry.seconds * 16_000).rounded())
    var out = [Float](repeating: 0, count: count)
    if let noise = entry.noise {
        switch noise.kind {
        case "hiss":
            out = white(count, seed: noise.seed!).map { Float($0 * noise.amplitude!) }
        case "fan", "pink":
            var low = 0.0
            var b = [Double](repeating: 0, count: 7)
            let shaped = white(count, seed: noise.seed!).map { w -> Double in
                guard noise.kind == "pink" else { low = (noise.pole ?? 0.92) * low + w; return low }
                b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759; b[2] = 0.969 * b[2] + w * 0.153852
                b[3] = 0.8665 * b[3] + w * 0.3104856; b[4] = 0.55 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.016898
                let value = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
                b[6] = w * 0.115926
                return value
            }
            let level = (shaped.reduce(0) { $0 + $1 * $1 } / Double(count)).squareRoot()
            out = shaped.map { Float($0 / level * noise.level!) }
        case "tone":
            out = (0 ..< count).map { Float(noise.amplitude! * sin(2 * Double.pi * noise.hertz! * Double($0) / 16_000)) }
        default:
            Issue.record("\(entry.name): no such noise \(noise.kind)")
        }
    }
    for second in entry.taps ?? [] {
        let at = Int(second * 16_000)
        for i in 0 ..< 400 where at + i < count {
            let t = Double(i)
            out[at + i] += Float(0.12 * exp(-t / 100) * (sin(2 * Double.pi * 180 * t / 16_000) + 0.5 * sin(2 * Double.pi * 2200 * t / 16_000)))
        }
    }
    if let clip = entry.clip, withClip {
        let at = Int((clip.at * 16_000).rounded())
        let length = clip.until.map { Int($0 * 16_000) } ?? phrase.count
        for (index, value) in phrase.prefix(length).enumerated() where at + index < count {
            out[at + index] += value * Float(clip.gain ?? 1)
        }
    }
    return out
}

@Test func codexF01AShortPhraseAnywhereKeepsAPieceAndHissFansRumblePinkNoiseHumToneAndKeyTapsAreSteady() throws {
    let phrase = try spokenPhrase()
    let cases = try steadyCases()
    #expect(cases.count >= 15)
    for entry in cases {
        #expect(SpeechGate.isSteady(audio(entry, phrase: phrase)[...]) == entry.steady, "\(entry.name)")
    }
}

/// What the recognizer writes for a piece: the phrase if it starts with it (said at 1 s), else the sentence.
private func says(_ piece: ArraySlice<Float>) -> String {
    let start = piece.startIndex
    let said = piece[start + 19_200 ..< start + 24_000]
    let level = (said.reduce(0) { $0 + $1 * $1 } / Float(said.count)).squareRoot()
    return level > 0.02 ? "Ja, genau." : "Die Lieferung kommt morgen um 10 Uhr."
}

@Test func codexF01CohereAndQwen3HearThePhraseBeforeALongPauseAndAPieceOfHissAloneIsStillNeverHeard() throws {
    let phrase = try spokenPhrase()
    let cases = try steadyCases()
    let clip = try #require(WAVDecoder.decode(Data(contentsOf: root.appendingPathComponent("Resources/speedtest.wav"))))
    #expect(clip.sampleRate == 16_000)
    for (id, fixture) in [(LocalCatalog.cohere, "Codex F01, Cohere"), (LocalCatalog.qwen3, "Codex F01, Qwen")] {
        let model = try #require(LocalCatalog.model(id)?.sherpa)
        let entry = try #require(cases.first { $0.name.hasPrefix(fixture) })
        // Codex's 36 s recording: the phrase, the pause to 31 s, then a sentence (5 s of the speed clip read aloud).
        func recording(withClip: Bool) -> [Float] {
            var out = audio(entry, phrase: phrase, withClip: withClip)
            out += [Float](repeating: 0, count: 31 * 16_000 - out.count)
            return out + clip.samples.prefix(5 * 16_000)
        }
        var pieces: [Int] = []
        let both = try model.transcribe(recording(withClip: true)) { piece in pieces.append(piece.count); return says(piece) }
        #expect(both == "Ja, genau. Die Lieferung kommt morgen um 10 Uhr.", "\(id)")
        #expect(pieces.count == 2, "\(id): \(pieces)")
        #expect(Double(pieces.first ?? 0) >= entry.seconds * 16_000, "\(id): the first piece holds the phrase and its pause")
        // The same recording without the phrase: only the sentence is heard.
        pieces = []
        let hiss = try model.transcribe(recording(withClip: false)) { piece in pieces.append(piece.count); return says(piece) }
        #expect(hiss == "Die Lieferung kommt morgen um 10 Uhr.", "\(id)")
        #expect(pieces.count == 1, "\(id): \(pieces)")
    }
}
