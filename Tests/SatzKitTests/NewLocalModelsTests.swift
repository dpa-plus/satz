import Foundation
import Testing
@testable import SatzKit

// Cohere Transcribe, Qwen3-ASR 0.6B, Canary 1B v2 and the German Parakeet
// (10.10.2026): offered, never downloaded until clicked. What is pinned here
// is what the research read off Hugging Face at those commits.

private func sherpa(_ id: String) throws -> SherpaModel {
    let model = try #require(LocalCatalog.model(id))
    return try #require(model.sherpa, "\(id)")
}

private let folder = URL(fileURLWithPath: "/m/sherpa/x", isDirectory: true)

// MARK: - What is pinned

@Test func cohereTranscribeIsPinnedToItsOfficialSherpaExport() throws {
    let model = try sherpa(LocalCatalog.cohere)
    #expect(model.kind == .cohereTranscribe)
    #expect(model.owner == "csukuangfj2")
    #expect(model.repo == "sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01")
    #expect(model.revision == "156a470cf08eefe706a0004f3c52d9ee567ca7a0")
    #expect(model.files.map(\.name) == ["encoder.int8.onnx", "encoder.int8.onnx.data", "decoder.int8.onnx", "tokens.txt"])
    #expect(model.files.map(\.bytes) == [3_090_822, 2_731_503_072, 153_250_705, 207_437])
    #expect(model.files.map(\.sha256) == [
        "cf704f8cfa90e3f0a76f9ffc05998bdf00ba9ae983192c14a85a3a5eb008b367",
        "bcf1b7148c8518ae52df1ad2d2fc2b4e89261ea23e6c874eef1d9f55bcbaa4a3",
        "8372ca6c8ff4db8b916ca3592f5c757a715e691b9edec751ba19b29fc854baf9",
        "013ede043ae2480e3a9205cc34550d9686100cc682bacc90f702facdfbb93035",
    ])
    #expect(model.bytes == 2_888_052_036)
    // The newer repositories are not csukuangfj's.
    let data = try #require(model.files.first { $0.name.hasSuffix(".data") })
    #expect(model.url(of: data).absoluteString
            == "https://huggingface.co/csukuangfj2/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01/resolve/156a470cf08eefe706a0004f3c52d9ee567ca7a0/encoder.int8.onnx.data")
}

@Test func qwen3ASRIsPinnedAndItsTokenizerFilesLiveInAFolder() throws {
    let model = try sherpa(LocalCatalog.qwen3)
    #expect(model.kind == .qwen3ASR && model.owner == "csukuangfj2")
    #expect(model.repo == "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25")
    #expect(model.revision == "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a")
    #expect(model.files.map(\.name) == ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx",
                                         "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json"])
    #expect(model.files.map(\.bytes) == [44_148_281, 182_491_662, 755_914_231, 2_776_833, 1_671_853, 12_487])
    #expect(model.bytes == 987_015_347)
    let vocab = try #require(model.files.first { $0.name == "tokenizer/vocab.json" })
    #expect(model.url(of: vocab).absoluteString
            == "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/tokenizer/vocab.json")
}

@Test func canary1BV2AndTheGermanParakeetComeFromTheirAuthorsRepositories() throws {
    let canary = try sherpa(LocalCatalog.canary1B)
    #expect(canary.kind == .canary && canary.owner == "Sarphix" && canary.repo == "canary-1b-v2-sherpa-onnx-int8")
    #expect(canary.revision == "7d513cd4f39f6c7dc75c13a284b5e345b37f6198")
    #expect(canary.files.map(\.bytes) == [857_602_351, 558_682_707, 224_406])
    #expect(canary.bytes == 1_416_509_464)

    let german = try sherpa(LocalCatalog.parakeetGerman)
    // The existing transducer kind: no new code path.
    #expect(german.kind == .nemoTransducer && german.owner == "x-ian" && german.repo == "sherpa-onnx-parakeet-primeline-de-int8")
    #expect(german.revision == "2a97df7e501bc25c6106a150a3379c5272088c53")
    #expect(german.bytes == 670_576_789)
    // Its tokens are Parakeet V3's, byte for byte.
    let v3 = try sherpa(LocalCatalog.parakeetV3)
    #expect(german.files.first { $0.name == "tokens.txt" } == v3.files.first { $0.name == "tokens.txt" })
}

@Test func theOldModelsKeepCsukuangfjAsTheirOwner() throws {
    for id in [LocalCatalog.parakeetV3, LocalCatalog.parakeetV2, LocalCatalog.canary, LocalCatalog.moonshineBase,
               LocalCatalog.moonshineTiny, LocalCatalog.senseVoice] {
        #expect(try sherpa(id).owner == "csukuangfj", "\(id)")
    }
}

@Test func theCardsSayWhatTheDownloadWeighs() {
    let size = { (id: String) in LocalCatalog.model(id)?.bytes.map { LocalFacts.size($0, language: .english) } }
    #expect(size(LocalCatalog.cohere) == "2.9 GB")
    #expect(size(LocalCatalog.qwen3) == "987 MB")
    #expect(size(LocalCatalog.canary1B) == "1.4 GB")
    #expect(size(LocalCatalog.parakeetGerman) == "671 MB")
}

// MARK: - How sherpa-onnx is given them

@Test func coherePointsTheEncoderAtItsGraphNotAtTheWeightsBesideIt() throws {
    let model = try sherpa(LocalCatalog.cohere)
    let settings = model.settings(folder: folder, spoken: .german, threads: 4)
    #expect(settings.cohere == .init(encoder: "/m/sherpa/x/encoder.int8.onnx", decoder: "/m/sherpa/x/decoder.int8.onnx",
                                     language: "de", punctuation: true, inverseNormalization: true))
    #expect(settings.tokens == "/m/sherpa/x/tokens.txt")
    #expect(settings.modelType.isEmpty && settings.transducer == nil && settings.canary == nil && settings.qwen3 == nil)
    // Found by its own name, beside the graph: sherpa-onnx loads it from there.
    #expect(model.files.contains { $0.name == "encoder.int8.onnx.data" })
    #expect(model.settings(folder: folder, spoken: .english).cohere?.language == "en")
}

@Test func cohereTranscribePunctuatesAndWritesNumbersLikeTheOthers() throws {
    let cohere = try #require(try sherpa(LocalCatalog.cohere).settings(folder: folder, spoken: .german).cohere)
    #expect(cohere.punctuation && cohere.inverseNormalization)
}

@Test func qwen3GetsItsTokenizerFolderAndLimitsWhichTheCAPILeavesAtZero() throws {
    let model = try sherpa(LocalCatalog.qwen3)
    let settings = model.settings(folder: folder, spoken: .german)
    #expect(settings.qwen3 == .init(convFrontend: "/m/sherpa/x/conv_frontend.onnx", encoder: "/m/sherpa/x/encoder.int8.onnx",
                                    decoder: "/m/sherpa/x/decoder.int8.onnx", tokenizer: "/m/sherpa/x/tokenizer",
                                    maxTotalLength: SherpaModel.qwen3MaxTotalLength, maxNewTokens: SherpaModel.qwen3MaxNewTokens))
    // Set, not left at zero (which the C API would read as unset).
    #expect(settings.qwen3.map { $0.maxTotalLength > 0 && $0.maxNewTokens > 0 } == true)
    // No tokens.txt: it has a tokenizer folder instead.
    #expect(settings.tokens.isEmpty)
    #expect(settings.cohere == nil && settings.canary == nil)
}

@Test func qwen3IsHeardInWindowsThatFitItsDecodersLength() throws {
    let model = try sherpa(LocalCatalog.qwen3)
    // The export's decoder holds 512 tokens: 40 s of audio filled it and came back as "language".
    #expect(model.windowSeconds == 15 && SherpaModel.qwen3MaxTotalLength == 512)
    // 12.5 audio tokens a second plus a prompt of 64 plus what is said must fit the total.
    let audioTokens = 13 * model.windowSeconds
    #expect(audioTokens + 64 + SherpaModel.qwen3MaxNewTokens <= SherpaModel.qwen3MaxTotalLength)
    #expect(!model.isToldTheLanguage)
}

@Test func coherePiecesAreNeverMoreThanItsThirtyFiveSeconds() throws {
    let model = try sherpa(LocalCatalog.cohere)
    #expect(model.windowSeconds == 30 && model.windowSeconds < 35)
    #expect(model.windowSeconds * 16_000 <= SherpaModel.longestCall)
    #expect(model.isToldTheLanguage && !model.padsEnd)
}

@Test func theGermanParakeetIsATransducerLikeV3() throws {
    let settings = try sherpa(LocalCatalog.parakeetGerman).settings(folder: folder, spoken: .german)
    #expect(settings.modelType == "nemo_transducer")
    #expect(settings.transducer == .init(encoder: "/m/sherpa/x/encoder.int8.onnx", decoder: "/m/sherpa/x/decoder.int8.onnx",
                                         joiner: "/m/sherpa/x/joiner.int8.onnx"))
    #expect(try sherpa(LocalCatalog.parakeetGerman).windowSeconds == 240)
}

@Test func canary1BV2IsToldTheLanguageLikeTheSmallOne() throws {
    let model = try #require(LocalCatalog.model(LocalCatalog.canary1B))
    #expect(model.toldLanguages == ["en", "de", "es", "fr"])
    #expect(model.sherpa?.settings(folder: folder, spoken: .german).canary?.language == "de")
    #expect(model.sherpa?.isToldTheLanguage == true)
}

// MARK: - Languages

@Test func cohereHearsFourteenLanguagesAndIsToldWhichOne() throws {
    let model = try #require(LocalCatalog.model(LocalCatalog.cohere))
    let codes = try #require(model.toldLanguages)
    #expect(codes.count == 14 && Set(codes).count == 14)
    #expect(Set(codes) == ["ar", "de", "el", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "vi", "zh"])
    #expect(model.languages.text(language: .german) == "14 Sprachen" && model.languages.text(language: .english) == "14 languages")
    // The choice among them, else the spoken language (always one of them).
    #expect(model.told(choice: "ko", spoken: .german) == "ko")
    #expect(model.told(choice: nil, spoken: .english) == "en")
    #expect(model.told(choice: "ru", spoken: .german) == "de")
    #expect(model.languages.list(language: .english) == "German, English, French, Spanish, Italian, Portuguese, Dutch, Polish, Greek, Chinese, Japanese, Korean, Vietnamese, Arabic")
}

@Test func theGermanParakeetsCardSaysItWritesSsForEszett() throws {
    let model = try #require(LocalCatalog.model(LocalCatalog.parakeetGerman))
    for language in Language.allCases {
        Language.current = language
        #expect(model.summary.contains("ss") && model.summary.contains("ß"), "\(language)")
    }
    Language.current = .german
}

@Test func theGermanParakeetHearsGermanOnlyAndSaysSo() throws {
    let model = try #require(LocalCatalog.model(LocalCatalog.parakeetGerman))
    #expect(model.languages.hearsGerman && !model.isEnglishOnly)
    #expect(model.languages.text(language: .german) == "Nur Deutsch")
    #expect(model.languages.text(language: .english) == "German only")
    #expect(model.toldLanguages == nil)
}

@Test func qwen3FindsTheLanguageItself() throws {
    let model = try #require(LocalCatalog.model(LocalCatalog.qwen3))
    #expect(model.toldLanguages == nil && model.languages.hearsGerman)
    #expect(model.languages.text(language: .english) == "30 languages")
}

@Test func theNewModelsAreRatedAsTheLeaderboardsTellAndTheCardsNameThem() throws {
    // Handy's scores for Cohere (92) and Canary 1B v2 (88); the rest in their spirit.
    #expect(LocalCatalog.model(LocalCatalog.cohere)?.accuracy == 0.92)
    #expect(LocalCatalog.model(LocalCatalog.canary1B)?.accuracy == 0.88)
    let best = LocalCatalog.all.filter { $0.sherpa != nil }.max { $0.accuracy < $1.accuracy }
    #expect(best?.id == LocalCatalog.cohere)
    // Qwen3 0.6B is behind Parakeet V3 in German on the leaderboard, and rated so.
    #expect((LocalCatalog.model(LocalCatalog.qwen3)?.accuracy ?? 1) < (LocalCatalog.model(LocalCatalog.parakeetV3)?.accuracy ?? 0))
    // Big models are rated slower than the small ones.
    #expect((LocalCatalog.model(LocalCatalog.cohere)?.speed ?? 1) < (LocalCatalog.model(LocalCatalog.parakeetV3)?.speed ?? 0))
}

@Test func theLeaderboardNumbersAreWordedInBothLanguagesAndNameTheirSource() throws {
    let cohere = try #require(LocalCatalog.model(LocalCatalog.cohere)?.published)
    #expect(LocalFacts.published(cohere, language: .english)
            == "3.3 % wrong words in German on FLEURS, 2.9 % on Common Voice; 6.3 % in English on average. Open ASR Leaderboard, not measured by satz.")
    #expect(LocalFacts.published(cohere, language: .german)
            == "3,3 % falsche Wörter auf Deutsch (FLEURS), 2,9 % (Common Voice); 6,3 % auf Englisch im Schnitt. Open ASR Leaderboard, nicht von satz gemessen.")
    // primeLine's are the maker's own, and compared with the model it was made from.
    let german = try #require(LocalCatalog.model(LocalCatalog.parakeetGerman)?.published)
    #expect(LocalFacts.published(german, language: .english)
            == "2.95 % wrong words in German on average (Parakeet V3: 3.64 %). The maker's own figures, not measured by satz.")
    #expect(LocalFacts.published(german, language: .german).hasSuffix("Angaben des Herstellers, nicht von satz gemessen."))
    // Whisper's are Argmax's, so there is nothing published to show for them here.
    #expect(LocalCatalog.model(LocalCatalog.turbo)?.published == nil)
    #expect(LocalCatalog.model(LocalCatalog.parakeetV2)?.published?.english == 6.43)
    for language in Language.allCases {
        for id in [LocalCatalog.cohere, LocalCatalog.qwen3, LocalCatalog.canary1B, LocalCatalog.parakeetGerman, LocalCatalog.parakeetV3, LocalCatalog.parakeetV2] {
            let errors = try #require(LocalCatalog.model(id)?.published)
            #expect(!LocalFacts.published(errors, language: language).contains("\u{2014}"), "\(id)")
        }
    }
}

// MARK: - Downloads

/// Answers each request by the file's path, so a file in a folder is told
/// from one beside it.
private final class FolderFiles: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = Self.bodies[url.path.components(separatedBy: "/resolve/").last.map { String($0.drop { $0 != "/" }.dropFirst()) } ?? ""]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct FolderDownloadTests {
    @Test func aFileInASubfolderIsFetchedIntoItAndCheckedLikeTheRest() async throws {
        let graph = Data(repeating: 7, count: 2_000)
        let vocab = Data(#"{"a": 1}"#.utf8)
        let model = SherpaModel(kind: .qwen3ASR, owner: "someone", repo: "tiny-qwen", revision: String(repeating: "b", count: 40), files: [
            .init("encoder.int8.onnx", Int64(graph.count), sha256: sha256Hex(graph)),
            .init("tokenizer/vocab.json", Int64(vocab.count), sha256: sha256Hex(vocab)),
        ])
        FolderFiles.bodies = ["encoder.int8.onnx": graph, "tokenizer/vocab.json": vocab]
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("satz-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: target) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FolderFiles.self]
        try await FileDownload(progress: { _ in }, configuration: configuration).run(model, into: target)

        #expect(try Data(contentsOf: target.appendingPathComponent("tokenizer/vocab.json")) == vocab)
        #expect(try Data(contentsOf: target.appendingPathComponent("encoder.int8.onnx")) == graph)
        #expect(model.damagedFiles(in: target, checkingBytes: true).isEmpty)
        // A missing file of the folder is a damaged model.
        try FileManager.default.removeItem(at: target.appendingPathComponent("tokenizer/vocab.json"))
        #expect(model.damagedFiles(in: target).map(\.name) == ["tokenizer/vocab.json"])
    }

    @Test func aModelWithAMissingFileIsNeverHandedToSherpa() throws {
        let model = try sherpa(LocalCatalog.qwen3)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("satz-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: SherpaModel.Failure.self) {
            try model.load(from: empty, marking: false) { _ in 1 }
        }
    }
}


// MARK: - Steady noise: Cohere makes text up for it

private func noiseFloor(seconds: Double, level: Float, seed: UInt64 = 7) -> [Float] {
    var state = seed
    var low: Float = 0
    var out: [Float] = []
    for _ in 0 ..< Int(seconds * 16_000) {
        // A small linear congruential generator: the same hiss on every run.
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let white = Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
        low = 0.92 * low + white
        out.append(low)
    }
    let rms = (out.map { $0 * $0 }.reduce(0, +) / Float(out.count)).squareRoot()
    return out.map { $0 / rms * level }
}

/// Words and pauses: bursts of a tone, each a different loudness, with gaps.
private func spokenLike(seconds: Double, over floor: Float = 0) -> [Float] {
    let hiss = floor > 0 ? noiseFloor(seconds: seconds, level: floor, seed: 11) : [Float](repeating: 0, count: Int(seconds * 16_000))
    return hiss.enumerated().map { index, base in
        let beat = index / 4_800                      // 0.3 s
        guard beat % 4 != 3 else { return base }       // a pause every fourth
        let loudness: Float = [0.30, 0.12, 0.22, 0.08, 0.26][beat % 5]
        return base + loudness * Float(sin(Double(index) * 0.05 + Double(beat)))
    }
}

@Test func aFanIsSteadyAndSpeechIsNot() {
    let rate = 16_000.0
    // Hiss at -30 and -45 dBFS, hum: one level all the way.
    #expect(SpeechGate.isSteady(noiseFloor(seconds: 12, level: 0.03)[...], sampleRate: rate))
    #expect(SpeechGate.isSteady(noiseFloor(seconds: 12, level: 0.006)[...], sampleRate: rate))
    let hum = (0 ..< 12 * 16_000).map { 0.02 * Float(sin(2 * Double.pi * 50 * Double($0) / rate)) }
    #expect(SpeechGate.isSteady(hum[...], sampleRate: rate))
    // Speech: syllables, pauses.
    #expect(!SpeechGate.isSteady(spokenLike(seconds: 12)[...], sampleRate: rate))
}

@Test func speechSixDecibelsOverTheFanItIsRecordedOverIsNotSteady() {
    // Faint words (twice the fan's level) over a fan: the hiss alone is the quiet frames.
    let fan = noiseFloor(seconds: 12, level: 0.01, seed: 3)
    let faint: [Float] = fan.enumerated().map { index, base in
        (index / 4_800) % 3 == 0 ? base + 0.02 * Float(sin(Double(index) * 0.05)) : base
    }
    #expect(!SpeechGate.isSteady(faint[...]))
}

@Test func tooLittleToJudgeAndDigitalSilenceAreNeverCalledSteady() {
    // Under 30 frames of 30 ms (0.9 s): too little to say.
    #expect(!SpeechGate.isSteady(noiseFloor(seconds: 0.8, level: 0.03)[...]))
    #expect(SpeechGate.isSteady(noiseFloor(seconds: 1.0, level: 0.03)[...]))
    // Nothing at all: the speech gate's business, not this one's.
    #expect(!SpeechGate.isSteady([Float](repeating: 0, count: 5 * 16_000)[...]))
    // A piece with a silent stretch in it (over a tenth of it) is not one steady level.
    let broken = noiseFloor(seconds: 4, level: 0.03) + [Float](repeating: 0, count: 2 * 16_000) + noiseFloor(seconds: 4, level: 0.03)
    #expect(!SpeechGate.isSteady(broken[...]))
}

@Test func onlyCohereAndQwen3AreKeptFromSteadyNoiseTheSpeechGateLetsThrough() throws {
    let hiss = noiseFloor(seconds: 12, level: 0.03)
    // The recording-level gate takes it for speech: it is louder than -45 dBFS.
    #expect(SpeechGate.hasSpeech(hiss))
    var calls = 0
    let cohere = try sherpa(LocalCatalog.cohere)
    #expect(cohere.makesUpTextForNoise)
    let text = try cohere.transcribe(hiss) { _ in calls += 1; return "Ich bin jetzt nicht mehr so gut" }
    #expect(text == "" && calls == 0)
    // Qwen3-ASR wrote a line of Chinese for a steady rumble, here too.
    let qwen = try sherpa(LocalCatalog.qwen3)
    #expect(qwen.makesUpTextForNoise)
    #expect(try qwen.transcribe(hiss) { _ in calls += 1; return "提纲：" } == "" && calls == 0)

    // The models that write nothing for noise are heard as before.
    for id in [LocalCatalog.parakeetV3, LocalCatalog.canary, LocalCatalog.canary1B, LocalCatalog.parakeetGerman] {
        let model = try sherpa(id)
        #expect(!model.makesUpTextForNoise)
        var heard = 0
        _ = try model.transcribe(hiss) { _ in heard += 1; return "words" }
        #expect(heard >= 1, "\(id)")
    }
}

@Test func coheresSpeechIsHeardAndOnlyTheSteadyPieceOfALongRecordingIsSkipped() throws {
    let cohere = try sherpa(LocalCatalog.cohere)
    var calls = 0
    let speech = spokenLike(seconds: 12)
    #expect(try cohere.transcribe(speech) { _ in calls += 1; return "Hallo Welt" } == "Hallo Welt" && calls == 1)

    // 40 s: speech, then a fan louder than the speech gate's level for the rest.
    let long = spokenLike(seconds: 20) + noiseFloor(seconds: 25, level: 0.03)
    var starts: [Int] = []
    let text = try cohere.transcribe(long) { piece in starts.append(piece.startIndex); return "Wörter" }
    #expect(text == "Wörter")
    #expect(starts.allSatisfy { $0 < 22 * 16_000 })
}

// MARK: - Qwen3's hotwords

@Test func theWordListBecomesHotwordsOfAtMostTwentyFourWordsAndTwoHundredFortyLetters() {
    #expect(SherpaModel.hotwordList(["Kubernetes", "Grafana", "Figma"]) == "Kubernetes,Grafana,Figma")
    #expect(SherpaModel.hotwordList([]) == "")
    // A comma or a line break inside a word would split it.
    #expect(SherpaModel.hotwordList(["Müller, Meier", "zwei\nZeilen", "  ", ""]) == "Müller Meier,zwei Zeilen")
    #expect(SherpaModel.hotwordList((0 ..< 40).map { "w\($0)" }).split(separator: ",").count == 24)
    let long = SherpaModel.hotwordList((0 ..< 40).map { _ in String(repeating: "a", count: 50) })
    #expect(long.count <= 240 && long.split(separator: ",").count == 4)
}

@Test func onlyQwen3IsGivenTheWordListAndKeepsItsTextOnlyIfNoWordWasLost() throws {
    let qwen = try sherpa(LocalCatalog.qwen3)
    #expect(qwen.takesHotwords)
    let speech = spokenLike(seconds: 8)
    var given: [String] = []
    // The hinted reading spells the name as listed, losing nothing: kept.
    let kept = try qwen.transcribe(speech, hotwords: ["Immofanten"]) { _, hotwords in
        given.append(hotwords)
        return hotwords.isEmpty ? "Wir sprechen über Immo Fanten und die Miete heute." : "Wir sprechen über Immofanten und die Miete heute."
    }
    #expect(given == ["", "Immofanten"])
    #expect(kept == "Wir sprechen über Immofanten und die Miete heute.")

    // The hinted reading dropped a sentence: the plain one stays.
    let plain = "Das ist der erste Satz hier. Und das ist der zweite Satz dort. Zum Schluss kommt noch ein dritter."
    let lost = try qwen.transcribe(speech, hotwords: ["Immofanten"]) { _, hotwords in
        hotwords.isEmpty ? plain : "Das ist der erste Satz hier."
    }
    #expect(lost == plain)

    // No word list, no second reading; and the others never get one.
    var calls = 0
    _ = try qwen.transcribe(speech, hotwords: []) { _, _ in calls += 1; return "Text" }
    #expect(calls == 1)
    for id in [LocalCatalog.parakeetV3, LocalCatalog.cohere, LocalCatalog.canary1B] {
        var hints: [String] = []
        _ = try sherpa(id).transcribe(speech, hotwords: ["Immofanten"]) { _, hotwords in hints.append(hotwords); return "Text" }
        #expect(hints == [""], "\(id)")
    }
}
