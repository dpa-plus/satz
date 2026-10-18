import Foundation
import Testing
@testable import SatzKit

// MARK: - Which models a Mac is offered

/// What WhisperKit's support config lists for "M2, M3, M4" (and, through its
/// fallback, for a chip it does not know yet, such as an M5), trimmed to the
/// builds that matter here.
private let newerChip: Set<String> = [
    "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small", "openai_whisper-small.en", "openai_whisper-large-v3",
    "openai_whisper-large-v3-v20240930", LocalCatalog.turboFull, LocalCatalog.turboCompatible, LocalCatalog.turbo,
    LocalCatalog.distil, LocalCatalog.distilCompatible,
]
/// The M1 list: no turbo build.
private let m1: Set<String> = [
    "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small", "openai_whisper-large-v3",
    LocalCatalog.turboCompatible, LocalCatalog.distilCompatible,
]

/// What both get besides their Turbo and Distil builds: sherpa-onnx's
/// models between them, the small Whisper builds after.
private let germanToo = [LocalCatalog.largeV3, LocalCatalog.cohere, LocalCatalog.parakeetUltra, LocalCatalog.parakeetV3, LocalCatalog.parakeetGerman,
                         LocalCatalog.canary1B, LocalCatalog.qwen3, LocalCatalog.canary]
private let englishAndMore = [LocalCatalog.parakeetV2, LocalCatalog.moonshineBase, LocalCatalog.moonshineTiny, LocalCatalog.senseVoice]
private let others = [LocalCatalog.small, LocalCatalog.base, LocalCatalog.tiny]
private let sherpaIDs = [LocalCatalog.cohere, LocalCatalog.parakeetV3, LocalCatalog.parakeetGerman, LocalCatalog.canary1B,
                         LocalCatalog.qwen3, LocalCatalog.canary, LocalCatalog.parakeetV2,
                         LocalCatalog.moonshineBase, LocalCatalog.moonshineTiny, LocalCatalog.senseVoice]

@Test func aNewerMacIsOfferedTheTurboBuildsAndNotTheCompatibleOne() {
    let ids = LocalCatalog.offered(supported: newerChip, hasApple: true).map(\.id)
    #expect(ids == [LocalCatalog.turbo, LocalCatalog.turboFull] + germanToo + [LocalCatalog.distil] + englishAndMore + others + [LocalCatalog.apple])
}

@Test func anM1GetsTheCompatibleBuildInsteadOfTheTurboOnes() {
    let ids = LocalCatalog.offered(supported: m1, hasApple: false).map(\.id)
    #expect(ids == [LocalCatalog.turboCompatible] + germanToo + [LocalCatalog.distilCompatible] + englishAndMore + others)
}

@Test func appleIsOfferedOnlyWhereMacOSHasIt() {
    #expect(LocalCatalog.offered(supported: newerChip, hasApple: false).allSatisfy { !$0.isApple })
    // sherpa-onnx runs on every Mac, whatever WhisperKit supports there.
    #expect(LocalCatalog.offered(supported: [], hasApple: true).map(\.id) == [LocalCatalog.cohere, LocalCatalog.parakeetUltra] + sherpaIDs.dropFirst() + [LocalCatalog.apple])
}

@Test func theDefaultLeadsTheList() {
    #expect(LocalCatalog.all.first?.id == Provider.local.defaultModel)
}

@Test func theDefaultIsRecommendedAndOnAnM1ItsCompatibleBuild() {
    #expect(LocalCatalog.recommended(supported: newerChip) == LocalCatalog.turbo)
    #expect(LocalCatalog.recommended(supported: m1) == LocalCatalog.turboCompatible)
    // A chip WhisperKit's list does not know yet keeps the default.
    #expect(LocalCatalog.recommended(supported: []) == LocalCatalog.turbo)
}

@Test func aBuildOnTheMacStaysInTheListEvenWhereItIsNotOffered() {
    // Downloaded on an M1 before satz checked: it can still be used or removed.
    let rows = LocalCatalog.rows(supported: m1, hasApple: false, current: LocalCatalog.turboCompatible) { $0 == LocalCatalog.turbo }
    #expect(rows == [LocalCatalog.turbo, LocalCatalog.turboCompatible] + germanToo + [LocalCatalog.distilCompatible] + englishAndMore + others)
}

@Test func theDefaultIsNotAddedOnAMacThatCannotRunIt() {
    let rows = LocalCatalog.rows(supported: m1, hasApple: false, current: LocalCatalog.turbo) { _ in false }
    #expect(rows == [LocalCatalog.turboCompatible] + germanToo + [LocalCatalog.distilCompatible] + englishAndMore + others)
}

@Test func aModelTypedInEarlierGetsARowOfItsOwn() {
    let rows = LocalCatalog.rows(supported: newerChip, hasApple: false, current: "openai_whisper-medium") { _ in false }
    #expect(rows.last == "openai_whisper-medium")
    #expect(LocalCatalog.model("openai_whisper-medium") == nil)
}

// MARK: - Your models and available ones

@Test func yourModelsAreTheOnesOnTheMacWithTheOneInUseFirst() {
    let onMac: Set = [LocalCatalog.turbo, LocalCatalog.moonshineTiny, LocalCatalog.parakeetV3]
    let sections = LocalCatalog.sections(supported: newerChip, hasApple: true, current: LocalCatalog.parakeetV3) { onMac.contains($0) }
    // Apple's is part of macOS, so it counts as one of yours.
    #expect(sections.yours == [LocalCatalog.parakeetV3, LocalCatalog.turbo, LocalCatalog.moonshineTiny, LocalCatalog.apple])
    #expect(sections.available.first == LocalCatalog.turboFull)
    #expect(Set(sections.available).isDisjoint(with: sections.yours))
    #expect(sections.yours.count + sections.available.count
            == LocalCatalog.offered(supported: newerChip, hasApple: true).count)
}

@Test func aModelInUseThatIsNotOnTheMacIsOnlyAvailable() {
    // The default, never downloaded: no card says it is in use.
    let sections = LocalCatalog.sections(supported: newerChip, hasApple: false, current: LocalCatalog.turbo) { _ in false }
    #expect(sections.yours.isEmpty)
    #expect(sections.available.first == LocalCatalog.turbo)
}

// MARK: - What each card says

@Test func everyModelHasASentenceInBothLanguagesWithoutAnEmDash() {
    for language in Language.allCases {
        Language.current = language
        for model in LocalCatalog.all {
            #expect(!model.summary.isEmpty, "\(model.id) in \(language)")
            #expect(!model.summary.contains("\u{2014}") && !model.name.contains("\u{2014}"))
            #expect(!model.languages.text(language: language).contains("\u{2014}"))
        }
    }
    Language.current = .german
    #expect(LocalCatalog.model(LocalCatalog.parakeetV3)?.summary == "Schnell und genau. 25 europäische Sprachen.")
    Language.current = .english
    #expect(LocalCatalog.model(LocalCatalog.parakeetV3)?.summary == "Fast and accurate. 25 European languages.")
    Language.current = .german
}

@Test func theEnglishOnlyModelsAreTheOnesThatHearNothingElse() {
    #expect(LocalCatalog.all.filter(\.isEnglishOnly).map(\.id) == [LocalCatalog.distil, LocalCatalog.distilCompatible,
                                                                   LocalCatalog.parakeetV2, LocalCatalog.moonshineBase, LocalCatalog.moonshineTiny])
}

@Test func whoHearsGerman() {
    let german = LocalCatalog.all.filter(\.languages.hearsGerman).map(\.id)
    #expect(german.contains(LocalCatalog.parakeetV3) && german.contains(LocalCatalog.canary) && german.contains(LocalCatalog.apple))
    #expect(!german.contains(LocalCatalog.senseVoice) && !german.contains(LocalCatalog.parakeetV2))
}

@Test func languagesAreNamedUpToFourAndCountedAbove() {
    let model = { (id: String) in LocalCatalog.model(id)!.languages }
    #expect(model(LocalCatalog.moonshineTiny).text(language: .german) == "Nur Englisch")
    #expect(model(LocalCatalog.moonshineTiny).text(language: .english) == "English only")
    #expect(model(LocalCatalog.apple).text(language: .german) == "Deutsch und Englisch")
    #expect(model(LocalCatalog.apple).text(language: .english) == "German and English")
    #expect(model(LocalCatalog.canary).text(language: .german) == "Englisch, Deutsch, Spanisch, Französisch")
    #expect(model(LocalCatalog.canary).text(language: .english) == "English, German, Spanish, French")
    #expect(model(LocalCatalog.parakeetV3).text(language: .german) == "25 Sprachen")
    #expect(model(LocalCatalog.turbo).text(language: .english) == "99 languages")
    #expect(model(LocalCatalog.senseVoice).text(language: .german) == "5 Sprachen")
    // The help lists them all where satz knows them all, never Whisper's 99.
    #expect(model(LocalCatalog.senseVoice).list(language: .german) == "Chinesisch, Englisch, Japanisch, Koreanisch, Kantonesisch")
    #expect(model(LocalCatalog.turbo).list(language: .german) == nil)
}

@Test func everyModelIsRatedBetweenZeroAndOne() {
    for model in LocalCatalog.all {
        #expect((0 ... 1).contains(model.accuracy) && (0 ... 1).contains(model.speed), "\(model.id)")
    }
    // Handy's scores for Handy's models.
    #expect(LocalCatalog.model(LocalCatalog.parakeetV2)?.accuracy == 0.85)
    #expect(LocalCatalog.model(LocalCatalog.moonshineTiny)?.speed == 0.95)
}

// MARK: - sherpa-onnx

@Test func eachSherpaModelWeighsWhatItsFilesWeigh() throws {
    for id in sherpaIDs {
        let model = try #require(LocalCatalog.model(id))
        let sherpa = try #require(model.sherpa, "\(id)")
        #expect(model.bytes == sherpa.bytes)
        // Qwen3-ASR's tokenizer is a folder.
        #expect(sherpa.files.contains { $0.name == "tokens.txt" } || sherpa.kind == .qwen3ASR, "\(id)")
        #expect(sherpa.files.allSatisfy { $0.bytes > 0 })
    }
    #expect(LocalCatalog.model(LocalCatalog.parakeetV3)?.bytes.map { LocalFacts.size($0, language: .german) } == "670 MB")
    #expect(LocalCatalog.model(LocalCatalog.moonshineTiny)?.bytes.map { LocalFacts.size($0, language: .german) } == "124 MB")
}

@Test func filesComeFromCsukuangfjsRepositoriesOneByOneAtAPinnedCommit() throws {
    let canary = try #require(LocalCatalog.model(LocalCatalog.canary)?.sherpa)
    let encoder = try #require(canary.files.first)
    // Not "main": a file changed there would not be the one whose checksum is pinned.
    #expect(canary.url(of: encoder).absoluteString
            == "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8/resolve/9077164e0d3dd1d5353743e89ceaa1d3a770838c/encoder.int8.onnx")
}

@Test func whisperBuildsAreTheOnlyOnesArgmaxIsAskedAbout() {
    #expect(Set(LocalCatalog.whisperIDs).isDisjoint(with: sherpaIDs + [LocalCatalog.apple]))
    #expect(LocalCatalog.whisperIDs.count == 9)
}

private let folder = URL(fileURLWithPath: "/m/sherpa/x", isDirectory: true)

@Test func parakeetIsANemoTransducer() throws {
    let settings = try #require(LocalCatalog.model(LocalCatalog.parakeetV3)?.sherpa).settings(folder: folder, spoken: .german, threads: 4)
    #expect(settings.modelType == "nemo_transducer")
    #expect(settings.transducer == .init(encoder: "/m/sherpa/x/encoder.int8.onnx", decoder: "/m/sherpa/x/decoder.int8.onnx",
                                         joiner: "/m/sherpa/x/joiner.int8.onnx"))
    #expect(settings.tokens == "/m/sherpa/x/tokens.txt")
    #expect(settings.canary == nil && settings.moonshine == nil && settings.senseVoice == nil)
    #expect(settings.threads == 4 && settings.sampleRate == 16_000 && settings.decoding == "greedy_search" && settings.provider == "cpu")
}

@Test func canaryIsToldTheSpokenLanguageToHearAndWrite() throws {
    let canary = try #require(LocalCatalog.model(LocalCatalog.canary)?.sherpa)
    #expect(canary.isToldTheLanguage && canary.windowSeconds == 30)
    #expect(canary.settings(folder: folder, spoken: .german).canary
            == .init(encoder: "/m/sherpa/x/encoder.int8.onnx", decoder: "/m/sherpa/x/decoder.int8.onnx", language: "de", punctuation: true))
    #expect(canary.settings(folder: folder, spoken: .english).canary?.language == "en")
    #expect(canary.settings(folder: folder, spoken: .english).modelType.isEmpty)
}

@Test func moonshineHasItsFourGraphs() throws {
    let settings = try #require(LocalCatalog.model(LocalCatalog.moonshineBase)?.sherpa).settings(folder: folder, spoken: .german)
    #expect(settings.moonshine == .init(preprocessor: "/m/sherpa/x/preprocess.onnx", encoder: "/m/sherpa/x/encode.int8.onnx",
                                        uncachedDecoder: "/m/sherpa/x/uncached_decode.int8.onnx",
                                        cachedDecoder: "/m/sherpa/x/cached_decode.int8.onnx"))
}

@Test func senseVoiceFindsTheLanguageItselfAndWritesNumbers() throws {
    let settings = try #require(LocalCatalog.model(LocalCatalog.senseVoice)?.sherpa).settings(folder: folder, spoken: .german)
    #expect(settings.senseVoice == .init(model: "/m/sherpa/x/model.int8.onnx", language: "auto", inverseNormalization: true))
    #expect(settings.featureDimension == 80)
}

@Test func canarysSpacesBeforePunctuationGo() {
    #expect(SherpaModel.tidy("schreibt mir eine Funktion , die alle Rechnungen liest . Danach  soll sie ?")
            == "schreibt mir eine Funktion, die alle Rechnungen liest. Danach soll sie?")
    #expect(SherpaModel.tidy("Pennies saved one and two at a time.") == "Pennies saved one and two at a time.")
}

@Test func eachPieceEndsInASecondOfSilence() {
    let padded = SherpaModel.padded([0.5, -0.5][...])
    #expect(padded.count == 2 + 16_000)
    #expect(padded.prefix(2) == [0.5, -0.5] && padded.dropFirst(2).allSatisfy { $0 == 0 })
}

@Test func onlyCanaryGetsSilenceAfterIt() {
    #expect(sherpaIDs.filter { LocalCatalog.model($0)?.sherpa?.padsEnd == true } == [LocalCatalog.canary1B, LocalCatalog.canary])
}

@Test func speechEndsAfterTheLastLoudFrame() {
    // 2 s of tone, then 1 s of quiet room noise.
    let tone = (0 ..< 32_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    let room = (0 ..< 16_000).map { Float(sin(Double($0) * 0.7)) * 0.0002 }
    let end = SpeechGate.speechEnd(tone + room)
    #expect(end.map { abs($0 - 32_000) <= 480 } == true)
    #expect(SpeechGate.speechEnd([Float](repeating: 0, count: 16_000)) == nil)
}

@Test func onlyParakeetIsHeardInPiecesOfFourMinutes() {
    // Its encoder holds 400 s: longer pieces ended satz. The others lose words past 30 s.
    let long = sherpaIDs.filter { LocalCatalog.model($0)?.sherpa?.windowSeconds == 240 }
    #expect(long == [LocalCatalog.parakeetV3, LocalCatalog.parakeetGerman, LocalCatalog.parakeetV2])
    // Qwen3-ASR's decoder holds audio and words in one fixed length: shorter still.
    let short = sherpaIDs.filter { !long.contains($0) && $0 != LocalCatalog.qwen3 }
    #expect(short.allSatisfy { LocalCatalog.model($0)?.sherpa?.windowSeconds == 30 })
    #expect(LocalCatalog.model(LocalCatalog.qwen3)?.sherpa?.windowSeconds == 15)
}

// MARK: - The bars

@Test func speedIsMappedOnALogScaleThroughFourPoints() {
    #expect(LocalScores.speed(secondsPer10: 0.05) == 1)
    #expect(LocalScores.speed(secondsPer10: 0.2) == 1)
    #expect(abs(LocalScores.speed(secondsPer10: 1) - 0.7) < 0.0001)
    #expect(abs(LocalScores.speed(secondsPer10: 3) - 0.4) < 0.0001)
    #expect(abs(LocalScores.speed(secondsPer10: 10) - 0.1) < 0.0001)
    #expect(LocalScores.speed(secondsPer10: 60) == 0.1)
    // Slower is never higher.
    let seconds = stride(from: 0.1, through: 12, by: 0.1).map { LocalScores.speed(secondsPer10: $0) }
    #expect(zip(seconds, seconds.dropFirst()).allSatisfy { $0 >= $1 })
}

@Test func theSpeedBarTakesThisMacsMeasurementThenArgmaxThenTheScore() {
    let bundled = LocalBenchmarks.bundled
    let here = LocalSpeed(secondsPer10: 1, measured: Date(), version: "0.5.0", machine: "Apple M5 Pro")
    let elsewhere = LocalSpeed(secondsPer10: 1, measured: Date(), version: "0.5.0", machine: "Apple M1")

    let measured = LocalScores.speed(of: LocalCatalog.parakeetV3, measured: [LocalCatalog.parakeetV3: here], chip: "Apple M5 Pro", benchmarks: bundled)
    #expect(abs(measured.score - 0.7) < 0.0001)
    #expect(measured.source == .measured(here))

    // Measured on another Mac: Argmax's estimate for a Whisper build...
    let small = LocalScores.speed(of: LocalCatalog.small, measured: [LocalCatalog.small: elsewhere], chip: "Apple M5 Pro", benchmarks: bundled)
    guard case .estimated(_, let chip, _) = small.source else { Issue.record("not estimated: \(small.source)"); return }
    #expect(chip == "Apple M4 Pro")
    // ...and the fixed score for one Argmax never measured.
    let canary = LocalScores.speed(of: LocalCatalog.canary, measured: [LocalCatalog.canary: elsewhere], chip: "Apple M5 Pro", benchmarks: bundled)
    #expect(canary.source == .rated)
    #expect(canary.score == 0.85)
}

// MARK: - Long recordings for the models that hear 30 s

@Test func aShortRecordingStaysOnePiece() {
    let samples = [Float](repeating: 0.1, count: 16_000 * 29)
    #expect(QuietWindows.split(samples).count == 1)
}

@Test func aLongRecordingIsCutWhereItIsQuietest() {
    // 70 s of tone with a quiet tenth of a second at 25 s and at 52 s.
    var samples = (0 ..< 16_000 * 70).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    for quiet in [25, 52] {
        for index in quiet * 16_000 ..< quiet * 16_000 + 1_600 { samples[index] = 0 }
    }
    let pieces = QuietWindows.split(samples)
    #expect(pieces.count == 3)
    #expect(pieces.map(\.count).reduce(0, +) == samples.count)
    #expect(pieces.allSatisfy { $0.count <= 30 * 16_000 })
    #expect(abs(pieces[0].count - (25 * 16_000 + 800)) <= 800)
    #expect(abs(pieces[0].count + pieces[1].count - (52 * 16_000 + 800)) <= 800)
}

// MARK: - Argmax's benchmarks, from trimmed copies of the live files (08.10.2026)

private let quality = """
{"model": "openai/whisper-large-v3-v20240930/turbo/632MB", "timestamp": "2024-10-18_20:10:30_GMT-0700", "average_wer": 6.86, "dataset_wer": {"librispeech": 1.95, "earnings22-12hours": 11.77}, "qoi": 0.93}
{"model": "openai/whisper-small", "timestamp": "2024-10-18_12:40:03_GMT-0700", "average_wer": 8.11, "dataset_wer": {"librispeech": 3.21, "earnings22-12hours": 13.0}, "qoi": 0.83}
{"model": "openai/whisper-large-v3-v20240930/turbo", "timestamp": "2024-10-18_19:37:26_GMT-0700", "average_wer": 6.72, "dataset_wer": {"librispeech": 1.92, "earnings22-12hours": 11.52}, "qoi": 0.94}
{"model": "openai/whisper-large-v3-v20240930/626MB", "timestamp": "2024-10-18_19:21:06_GMT-0700", "average_wer": 7.15, "dataset_wer": {"librispeech": 1.96, "earnings22-12hours": 12.35}, "qoi": 0.93}
{"model": "openai/whisper-base", "timestamp": "2024-10-18_20:25:50_GMT-0700", "average_wer": 10.67, "dataset_wer": {"librispeech": 4.94, "earnings22-12hours": 16.4}, "qoi": 0.67}
"""

private let multilingual = """
Model,Forced Tokens,Average WER,WER_sl,WER_nl,WER_de,WER_en,WER_tr
openai/whisper-large-v3-v20240930,False,51.57,36.9,11.46,14.01,12.54,31.24
openai/whisper-large-v3-v20240930,True,46.09,27.13,8.91,12.26,12.13,24.29
openai/whisper-small,False,96.89,116.31,60.49,49.17,18.2,108.8
openai/whisper-small,True,69.14,49.09,19.94,23.87,17.35,33.32
openai/whisper-large-v3-v20240930/626MB,False,52.29,39.68,11.63,14.69,13.39,31.2
openai/whisper-large-v3-v20240930/626MB,True,47.64,30.62,9.05,13.21,13.03,24.11
"""

private let performance = """
{"model": "openai/whisper-large-v3-v20240930/turbo/632MB", "device": "Apple M4 Pro", "os": "macOS 15.7.0", "timestamp": "2025-09-16T21:32:49Z", "speed": 15.78, "tokens_per_second": 61.83, "dataset_speed": {"earnings22-10mins": 25.25, "librispeech-10mins": 11.49}, "average_wer": 6.9, "qoi": 0.68, "commit_hash": "c814cae"}
{"model": "openai/whisper-large-v3-v20240930/626MB", "device": "Apple M4 Pro", "os": "macOS 15.7.0", "timestamp": "2025-09-16T21:27:33Z", "speed": 10.46, "tokens_per_second": 42.46, "dataset_speed": {"librispeech-10mins": 7.28, "earnings22-10mins": 18.62}, "average_wer": 6.7, "qoi": 0.7, "commit_hash": "c814cae"}
{"model": "openai/whisper-large-v3-v20240930/626MB", "device": "Apple M4 Pro", "os": "macOS 26.0.1", "timestamp": "2025-10-08T05:51:57Z", "speed": 10.46, "tokens_per_second": 43.22, "dataset_speed": {"librispeech-10mins": 7.32, "earnings22-10mins": 18.42}, "average_wer": 6.42, "qoi": 0.7, "commit_hash": "3f451e1"}
{"model": "openai/whisper-large-v3-v20240930/626MB", "device": "Apple M1", "os": "macOS 26.1.0", "timestamp": "2025-10-07T19:00:42Z", "speed": 6.28, "tokens_per_second": 26.09, "dataset_speed": {"librispeech-10mins": 4.65, "earnings22-10mins": 10.48}, "average_wer": 10.63, "qoi": 0.69, "commit_hash": "3f451e1"}
{"model": "openai/whisper-small", "device": "Apple M3 Max", "os": "macOS 15.5.0", "timestamp": "2025-06-16T04:48:28Z", "speed": 21.36, "tokens_per_second": 81.16, "dataset_speed": {"earnings22-10mins": 39.28, "librispeech-10mins": 14.69}, "average_wer": 8.7, "qoi": 0.55, "commit_hash": "8c0acbd"}
{"model": "openai/whisper-small", "device": "Apple M3 Max", "os": "macOS 15.1.0", "timestamp": "2024-10-30T07:35:00Z", "speed": 24.64, "tokens_per_second": 91.73, "dataset_speed": {"earnings22-10mins": 45.0, "librispeech-10mins": 16.99}, "average_wer": 9.01, "qoi": 0.55, "commit_hash": "a9b92c4"}
{"model": "openai/whisper-large-v3-v20240930/turbo/632MB", "device": "iPhone 14", "os": "iOS 18.7", "timestamp": "2025-09-17T00:05:21Z", "speed": 6.97, "tokens_per_second": 25.14, "dataset_speed": {"librispeech-10mins": 5.09, "earnings22-10mins": 11.07}, "average_wer": 6.49, "qoi": 0.7, "commit_hash": "c814cae"}
"""

@Test func englishErrorsAreReadByFieldName() {
    let english = LocalBenchmarks.parseEnglish(Data(quality.utf8), ids: LocalCatalog.whisperIDs)
    #expect(english == [LocalCatalog.turbo: 6.86, LocalCatalog.turboFull: 6.72, LocalCatalog.turboCompatible: 7.15,
                        LocalCatalog.small: 8.11, LocalCatalog.base: 10.67])
}

@Test func germanErrorsAreTheRowsWhereWhisperFoundTheLanguage() {
    let german = LocalBenchmarks.parseGerman(Data(multilingual.utf8), ids: LocalCatalog.whisperIDs)
    // No row for the turbo builds: no number, not another build's.
    #expect(german == [LocalCatalog.turboCompatible: 14.69, LocalCatalog.small: 49.17])
}

@Test func germanIsFoundWhereverItsColumnMoves() {
    let moved = """
    WER_de,Average WER,Model,Forced Tokens
    23.87,69.14,openai/whisper-small,True
    49.17,96.89,openai/whisper-small,False
    """
    #expect(LocalBenchmarks.parseGerman(Data(moved.utf8), ids: [LocalCatalog.small]) == [LocalCatalog.small: 49.17])
}

@Test func speedIsEachChipsLatestLibriSpeechRunOnMacsOnly() {
    let speed = LocalBenchmarks.parseSpeed(Data(performance.utf8), ids: LocalCatalog.whisperIDs)
    #expect(speed[LocalCatalog.turbo] == ["Apple M4 Pro": 11.49])
    #expect(speed[LocalCatalog.turboCompatible] == ["Apple M4 Pro": 7.32, "Apple M1": 4.65])
    #expect(speed[LocalCatalog.small] == ["Apple M3 Max": 14.69])
    #expect(speed[LocalCatalog.turboFull] == nil)
}

@Test func filesThatChangedShapeGiveNothingRatherThanNonsense() {
    let html = Data("<html>Space is sleeping</html>".utf8)
    #expect(LocalBenchmarks.parseEnglish(html, ids: LocalCatalog.whisperIDs).isEmpty)
    #expect(LocalBenchmarks.parseGerman(html, ids: LocalCatalog.whisperIDs).isEmpty)
    #expect(LocalBenchmarks.parseSpeed(html, ids: LocalCatalog.whisperIDs).isEmpty)
    let renamed = Data("Model,Forced,WER_german\nopenai/whisper-small,False,49.17\n".utf8)
    #expect(LocalBenchmarks.parseGerman(renamed, ids: LocalCatalog.whisperIDs).isEmpty)
}

@Test func theShippedNumbersCoverEveryWhisperBuild() {
    for id in LocalCatalog.whisperIDs {
        #expect(LocalBenchmarks.bundled.english[id] != nil)
        #expect(LocalBenchmarks.bundled.speed[id]?["Apple M4 Pro"] != nil)
    }
    #expect(LocalBenchmarks.bundled.german[LocalCatalog.turbo] == nil)
}

// MARK: - The nearest chip

private let measuredChips = ["Apple M1", "Apple M2", "Apple M2 Pro", "Apple M2 Ultra", "Apple M3 Pro", "Apple M3 Max", "Apple M4", "Apple M4 Pro"]

@Test(arguments: [
    ("Apple M5 Pro", "Apple M4 Pro"),
    ("Apple M4 Pro", "Apple M4 Pro"),
    ("Apple M5", "Apple M4"),
    ("Apple M3", "Apple M2"),
    ("Apple M5 Max", "Apple M3 Max"),
    ("Apple M4 Max", "Apple M3 Max"),
    ("Apple M5 Ultra", "Apple M2 Ultra"),
    ("Apple M1 Pro", "Apple M1"),
    ("Apple M1 Max", "Apple M1"),
])
func eachChipFindsTheNearestOneArgmaxMeasured(chip: String, nearest: String) {
    #expect(Chip(chip)?.nearest(in: measuredChips) == nearest)
}

@Test func neverANewerChipAndNeverAnIntelMac() {
    #expect(Chip("Apple M1")?.nearest(in: ["Apple M2", "Apple M4 Pro"]) == nil)
    #expect(Chip("Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz") == nil)
    #expect(Chip("Apple M4 Pro")?.name == "Apple M4 Pro")
}

@Test func theEstimateIsTenSecondsOverArgmaxsSpeed() throws {
    let estimate = try #require(LocalBenchmarks.bundled.estimate(LocalCatalog.turbo, chip: "Apple M5 Pro"))
    #expect(estimate.chip == "Apple M4 Pro")
    #expect(abs(estimate.secondsPer10 - 10 / 11.49) < 0.0001)
    #expect(LocalBenchmarks.bundled.estimate(LocalCatalog.apple, chip: "Apple M5 Pro") == nil)
    #expect(LocalBenchmarks.bundled.estimate(LocalCatalog.turbo, chip: nil) == nil)
}

@Test func anEstimateFollowsWhatThisMacMeasuredOnAnotherModel() throws {
    let bundled = LocalBenchmarks.bundled
    let argmaxTurbo = try #require(bundled.estimate(LocalCatalog.turbo, chip: "Apple M5 Pro")).secondsPer10
    let argmaxSmall = try #require(bundled.estimate(LocalCatalog.small, chip: "Apple M5 Pro")).secondsPer10
    let old = LocalSpeed(secondsPer10: 9, measured: Date(timeIntervalSince1970: 0), version: "0.4.1", machine: "Apple M5 Pro")
    let turbo = LocalSpeed(secondsPer10: 2 * argmaxTurbo, measured: Date(), version: "0.4.1", machine: "Apple M5 Pro")
    let elsewhere = LocalSpeed(secondsPer10: 50, measured: Date().addingTimeInterval(60), version: "0.4.1", machine: "Apple M1")

    // Twice Argmax's time on Turbo here, so twice for Small too: the most
    // recent measurement from this chip counts, another Mac's never.
    let scaled = try #require(bundled.estimate(LocalCatalog.small, chip: "Apple M5 Pro",
                                               measured: [LocalCatalog.turboFull: old, LocalCatalog.turbo: turbo, LocalCatalog.turboCompatible: elsewhere]))
    #expect(abs(scaled.secondsPer10 - 2 * argmaxSmall) < 0.0001)
    #expect(scaled.scaledBy == LocalCatalog.turbo)

    // Nothing measured on this chip: Argmax's number as it is.
    let plain = try #require(bundled.estimate(LocalCatalog.small, chip: "Apple M5 Pro", measured: [LocalCatalog.turbo: elsewhere]))
    #expect(abs(plain.secondsPer10 - argmaxSmall) < 0.0001)
    #expect(plain.scaledBy == nil)
}

// MARK: - Speed measured here

@Test func aMeasurementIsScaledToTenSecondsOfSpeech() {
    #expect(LocalSpeed.secondsPer10(elapsed: 0.7, clipSeconds: 10) == 0.7)
    #expect(abs(LocalSpeed.secondsPer10(elapsed: 1.5, clipSeconds: 20) - 0.75) < 0.0001)
    #expect(LocalSpeed.secondsPer10(elapsed: 1, clipSeconds: 0) == 0)
}

@Test func theSpeedClipIsTenSecondsOf16kHzMono() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/speedtest.wav")
    let clip = try #require(WAVDecoder.decode(try Data(contentsOf: file)))
    #expect(clip.sampleRate == 16_000)
    #expect(clip.samples.count == 160_000)
    #expect(SpeechGate.hasSpeech(clip.samples))
}

@Test func aWAVReadsBackWhatWasWritten() throws {
    let samples: [Float] = [0, 0.5, -0.5, 1, -1]
    let decoded = try #require(WAVDecoder.decode(WAVEncoder.encode(samples: samples, sampleRate: 16_000)))
    #expect(decoded.sampleRate == 16_000)
    #expect(zip(decoded.samples, samples).allSatisfy { abs($0 - $1) < 0.0001 })
}

@Test func aWAVWithAnExtraChunkStillReads() throws {
    var data = WAVEncoder.encode(samples: [0.25, -0.25], sampleRate: 16_000)
    // A LIST chunk before the audio, as some editors write one.
    let list = Data("LIST".utf8) + Data([5, 0, 0, 0]) + Data("INFOx".utf8) + Data([0])
    data.insert(contentsOf: list, at: 36)
    let decoded = try #require(WAVDecoder.decode(data))
    #expect(decoded.samples.count == 2)
    #expect(WAVDecoder.decode(Data("not a wav".utf8)) == nil)
}

// MARK: - Wording

@Test func sizesAreMegabytesUnderAThousandAndGigabytesAbove() {
    #expect(LocalFacts.size(645_668_913, language: .german) == "646 MB")
    #expect(LocalFacts.size(486_487_465, language: .english) == "486 MB")
    #expect(LocalFacts.size(1_638_464_446, language: .german) == "1,6 GB")
    #expect(LocalFacts.size(1_638_464_446, language: .english) == "1.6 GB")
    #expect(LocalFacts.size(999_700_000, language: .english) == "1.0 GB")
}

@Test func speedsSayWhetherTheyAreMeasuredOrEstimated() {
    #expect(LocalFacts.speed(0.71, estimated: false, language: .german) == "0,7 s für 10 s Sprechen")
    #expect(LocalFacts.speed(0.87, estimated: true, language: .german) == "ca. 0,9 s für 10 s Sprechen")
    #expect(LocalFacts.speed(0.71, estimated: false, language: .english) == "0.7 s per 10 s of speech")
    #expect(LocalFacts.speed(0.87, estimated: true, language: .english) == "about 0.9 s per 10 s of speech")
    #expect(LocalFacts.speed(0.02, estimated: false, language: .english) == "0.1 s per 10 s of speech")
}

@Test func errorsNameOnlyTheLanguagesThatHaveANumber() {
    #expect(LocalFacts.errors(english: 6.86, german: 14.69, language: .german) == "6,9 % Fehler Englisch, 14,7 % Deutsch")
    #expect(LocalFacts.errors(english: 6.86, german: 14.69, language: .english) == "6.9 % errors in English, 14.7 % in German")
    #expect(LocalFacts.errors(english: 6.86, german: nil, language: .german) == "6,9 % Fehler Englisch")
    #expect(LocalFacts.errors(english: nil, german: 3.67, language: .english) == "3.7 % errors in German")
    #expect(LocalFacts.errors(english: nil, german: nil, language: .german) == nil)
}

@Test func noFactCarriesAnEmDash() {
    let texts = [
        LocalFacts.speed(1, estimated: true, language: .german), LocalFacts.speed(1, estimated: true, language: .english),
        LocalFacts.errors(english: 1, german: 2, language: .german) ?? "", LocalFacts.errors(english: 1, german: 2, language: .english) ?? "",
    ]
    #expect(texts.allSatisfy { !$0.contains("\u{2014}") })
}

// MARK: - Long recordings through sherpa-onnx, piece by piece

/// 70 s of tone with quiet spots at 25 s and 52 s: three pieces for a model
/// that hears 30 s at a time.
private let seventySeconds: [Float] = {
    var samples = (0 ..< 16_000 * 70).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    for quiet in [25, 52] {
        for index in quiet * 16_000 ..< quiet * 16_000 + 1_600 { samples[index] = 0 }
    }
    return samples
}()

private let moonshine = LocalCatalog.model(LocalCatalog.moonshineBase)!.sherpa!

/// Counts the recognizer calls, from inside a test's task.
private final class Calls: @unchecked Sendable {
    var starts: [Int] = []
}

@Test func everyPieceIsHeardAndTheTextsJoined() throws {
    let calls = Calls()
    let text = try moonshine.transcribe(seventySeconds) { piece in
        calls.starts.append(piece.startIndex)
        return "piece \(calls.starts.count) ,"
    }
    #expect(calls.starts.count == 3)
    #expect(text == "piece 1, piece 2, piece 3,")
}

@Test func aPieceThatStaysEmptyLosesNothingSilently() {
    // The second piece comes back empty, also when tried again up to its
    // last sound: the first and third must not stand for the whole recording.
    let calls = Calls()
    #expect(throws: SherpaModel.Failure.pieceNotHeard) {
        try moonshine.transcribe(seventySeconds) { piece in
            calls.starts.append(piece.startIndex)
            return piece.startIndex > 0 && piece.startIndex < 50 * 16_000 ? "" : "words"
        }
    }
    // Stopped at the empty piece, after one more try of it.
    #expect(calls.starts.count == 3)
}

@Test func anEmptyPieceIsTriedOnceMoreUpToItsLastSound() throws {
    // Speech cut off, then a second of quiet: Parakeet wrote nothing for it.
    let speech = (0 ..< 32_000).map { Float(sin(Double($0) * 0.05)) * 0.3 } + [Float](repeating: 0.0001, count: 16_000)
    let parakeet = LocalCatalog.model(LocalCatalog.parakeetV3)!.sherpa!
    let calls = Calls()
    let text = try parakeet.transcribe(speech) { piece in
        calls.starts.append(piece.count)
        return piece.count == speech.count ? "" : "Pennies saved"
    }
    #expect(text == "Pennies saved")
    #expect(calls.starts.count == 2 && calls.starts[1] < speech.count)
}

@Test func aQuietPieceIsNeverSentAndSilenceIsNothing() throws {
    // 40 s: speech, then from 25 s on only quiet, which goes to no model.
    var samples = (0 ..< 16_000 * 40).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    for index in 25 * 16_000 ..< samples.count { samples[index] = 0 }
    let calls = Calls()
    let text = try moonshine.transcribe(samples) { piece in
        calls.starts.append(piece.startIndex)
        return "words"
    }
    #expect(text == "words" && calls.starts == [0])
    #expect(try moonshine.transcribe([Float](repeating: 0, count: 16_000 * 5)) { _ in "made up" } == "")
}

@Test func aCancelledDictationStopsBeforeItsNextPiece() async {
    let calls = Calls()
    let task = Task {
        try moonshine.transcribe(seventySeconds) { piece in
            calls.starts.append(piece.startIndex)
            // Thrown away while its first piece is being heard.
            withUnsafeCurrentTask { $0?.cancel() }
            return "words"
        }
    }
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(calls.starts.count == 1)
}

// MARK: - The language Canary is told

@Test func theModelsThatAreToldTheLanguageAreCanaryAndCohere() throws {
    #expect(LocalCatalog.all.filter { $0.toldLanguages != nil }.map(\.id) == [LocalCatalog.cohere, LocalCatalog.canary1B, LocalCatalog.canary])
}

@Test func canaryIsToldItsChosenLanguageElseTheSpokenOne() throws {
    let canary = try #require(LocalCatalog.model(LocalCatalog.canary))
    #expect(canary.toldLanguages == ["en", "de", "es", "fr"])
    #expect(canary.told(choice: "es", spoken: .german) == "es")
    #expect(canary.told(choice: nil, spoken: .english) == "en")
    // A code Canary does not know falls back to the spoken language.
    #expect(canary.told(choice: "it", spoken: .german) == "de")
    // Only Canary and Cohere are told; the others find the language or hear one.
    #expect(LocalCatalog.model(LocalCatalog.parakeetV3)?.told(choice: "es", spoken: .german) == nil)
}

// MARK: - Test mode and the models folder

@Test func testModeNeedsAStateFileAndTheModelsFolderNeedsTestMode() {
    #expect(LaunchMode.parse(["satz"]) == .normal)
    #expect(LaunchMode.parse(["satz", "--dev-control", "/s/state.json"]) == .test(stateFile: "/s/state.json", modelsFolder: nil))
    #expect(LaunchMode.parse(["satz", "--test-audio", "a.wav", "--dev-control", "/s/state.json", "--models-dir", "/m"])
            == .test(stateFile: "/s/state.json", modelsFolder: "/m"))
    // The case Codex found: no state file, so neither test mode nor another folder.
    guard case .invalid = LaunchMode.parse(["satz", "--models-dir", "/tmp/x", "--dev-control"]) else {
        Issue.record("accepted --dev-control without a state file"); return
    }
    for broken in [["satz", "--dev-control", "--models-dir", "/m"], ["satz", "--models-dir", "/m"],
                   ["satz", "--dev-control", "/s/state.json", "--models-dir"], ["satz", "--dev-control", ""]] {
        guard case .invalid = LaunchMode.parse(broken) else { Issue.record("accepted \(broken)"); continue }
    }
}

@Test func onlyTheUsersSatzOrATestCopyWithItsOwnFolderChangesModels() {
    #expect(LaunchMode.normal.canChangeModels)
    #expect(LaunchMode.test(stateFile: "/s", modelsFolder: "/m").canChangeModels)
    #expect(!LaunchMode.test(stateFile: "/s", modelsFolder: nil).canChangeModels)
    #expect(!LaunchMode.invalid("x").canChangeModels)
    #expect(LaunchMode.invalid("x").modelsFolder == nil && LaunchMode.invalid("x").stateFile == nil)
}

// MARK: - Downloads

/// A model whose two small files are already in a fresh folder.
private func cachedModel() throws -> (SherpaModel, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = Data(repeating: 1, count: 10), tokens = Data(repeating: 2, count: 4)
    try model.write(to: folder.appendingPathComponent("model.int8.onnx"))
    try tokens.write(to: folder.appendingPathComponent("tokens.txt"))
    // A repository that does not exist: nothing here may reach the network.
    return (SherpaModel(kind: .senseVoice, repo: "satz-test-none", revision: String(repeating: "0", count: 40),
                        files: [.init("model.int8.onnx", 10, sha256: sha256Hex(model)), .init("tokens.txt", 4, sha256: sha256Hex(tokens))]), folder)
}

@Test func filesAlreadyThereWithTheirChecksumAreKept() async throws {
    let (model, folder) = try cachedModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    try await FileDownload(progress: { _ in }).run(model, into: folder)
}

@Test func aCancelledDownloadNeverCountsAsDoneEvenWhenEverythingWasThere() async throws {
    let (model, folder) = try cachedModel()
    defer { try? FileManager.default.removeItem(at: folder) }
    let download = FileDownload(progress: { _ in })
    download.cancel()
    await #expect(throws: CancellationError.self) { try await download.run(model, into: folder) }
}
