import Foundation
import Testing
@testable import SatzKit

// MARK: - Which models a Mac is offered

/// What WhisperKit's support config lists for "M2, M3, M4" (and, through its
/// fallback, for a chip it does not know yet, such as an M5), trimmed to the
/// builds that matter here.
private let newerChip: Set<String> = [
    "openai_whisper-base", "openai_whisper-small", "openai_whisper-small.en", "openai_whisper-large-v3-v20240930",
    LocalCatalog.turboFull, LocalCatalog.turboCompatible, LocalCatalog.turbo,
]
/// The M1 list: no turbo build.
private let m1: Set<String> = [
    "openai_whisper-base", "openai_whisper-small", "openai_whisper-large-v3", LocalCatalog.turboCompatible,
]

@Test func aNewerMacIsOfferedTheTurboBuildsAndNotTheCompatibleOne() {
    let ids = LocalCatalog.offered(supported: newerChip, hasApple: true).map(\.id)
    #expect(ids == [LocalCatalog.turbo, LocalCatalog.turboFull, LocalCatalog.small, LocalCatalog.apple])
}

@Test func anM1GetsTheCompatibleBuildInsteadOfTheTurboOnes() {
    let ids = LocalCatalog.offered(supported: m1, hasApple: false).map(\.id)
    #expect(ids == [LocalCatalog.turboCompatible, LocalCatalog.small])
}

@Test func appleIsOfferedOnlyWhereMacOSHasIt() {
    #expect(LocalCatalog.offered(supported: newerChip, hasApple: false).allSatisfy { !$0.isApple })
    #expect(LocalCatalog.offered(supported: [], hasApple: true).map(\.id) == [LocalCatalog.apple])
}

@Test func theDefaultLeadsTheList() {
    #expect(LocalCatalog.all.first?.id == Provider.local.defaultModel)
}

@Test func aBuildOnTheMacStaysInTheListEvenWhereItIsNotOffered() {
    // Downloaded on an M1 before satz checked: it can still be used or removed.
    let rows = LocalCatalog.rows(supported: m1, hasApple: false, current: LocalCatalog.turboCompatible) { $0 == LocalCatalog.turbo }
    #expect(rows == [LocalCatalog.turbo, LocalCatalog.turboCompatible, LocalCatalog.small])
}

@Test func theDefaultIsNotAddedOnAMacThatCannotRunIt() {
    let rows = LocalCatalog.rows(supported: m1, hasApple: false, current: LocalCatalog.turbo) { _ in false }
    #expect(rows == [LocalCatalog.turboCompatible, LocalCatalog.small])
}

@Test func aModelTypedInEarlierGetsARowOfItsOwn() {
    let rows = LocalCatalog.rows(supported: newerChip, hasApple: false, current: "openai_whisper-medium") { _ in false }
    #expect(rows.last == "openai_whisper-medium")
    #expect(LocalCatalog.model("openai_whisper-medium") == nil)
}

@Test func onlySmallCarriesATag() {
    #expect(LocalCatalog.all.filter { $0.tag != nil }.map(\.id) == [LocalCatalog.small])
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
    #expect(english == [LocalCatalog.turbo: 6.86, LocalCatalog.turboFull: 6.72, LocalCatalog.turboCompatible: 7.15, LocalCatalog.small: 8.11])
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

@Test func onlyANumberFromThisChipAndThisSatzIsCurrent() {
    let speed = LocalSpeed(secondsPer10: 0.7, measured: Date(), version: "0.5.0", machine: "Apple M5 Pro")
    #expect(speed.isCurrent(chip: "Apple M5 Pro", version: "0.5.0"))
    // An update can change how fast a model runs: measured again, as on another Mac.
    #expect(!speed.isCurrent(chip: "Apple M5 Pro", version: "0.5.1"))
    #expect(!speed.isCurrent(chip: "Apple M4", version: "0.5.0"))
    #expect(speed.isCurrent(chip: nil, version: "0.5.0"))
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
