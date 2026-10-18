import CryptoKit
import Foundation
import Testing
@testable import SatzKit

// Fixes to the Mac's local engines (review of 09.10.2026): one speech/noise
// decision for a whole recording, Parakeet heard in pieces, model files that
// are checked and cannot crash the app twice.

private let rate = 16_000

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A recorder's hum: 50 Hz.
private func hum(_ seconds: Double, amplitude: Float) -> [Float] {
    (0 ..< Int(seconds * Double(rate))).map { amplitude * Float(sin(2 * Double.pi * 50 * Double($0) / Double(rate))) }
}

/// Words from a quiet microphone: 0.3 s of a tone, 0.1 s of pause, over a hum.
/// Its loudest frames sit under 0.0056 (a quarter of what a close microphone
/// gives), so they only count as speech next to a recording that has real
/// silence in it.
private func quietVoice(_ seconds: Double) -> [Float] {
    let under = hum(seconds, amplitude: 0.003)
    return under.enumerated().map { index, floor in
        let burst = (index / (rate / 10)) % 4 != 3
        return floor + (burst ? 0.006 * Float(sin(Double(index) * 0.2)) : 0)
    }
}

private func loudVoice(_ seconds: Double) -> [Float] {
    (0 ..< Int(seconds * Double(rate))).map { 0.3 * Float(sin(Double($0) * 0.05)) }
}

private let silence10 = [Float](repeating: 0, count: 10 * rate)

private final class Pieces: @unchecked Sendable {
    var starts: [Int] = []
    var lengths: [Int] = []
}

// MARK: - LE-01: one decision for the whole recording

@Test func quietWordsStayInTheTextWhenMoreSpeechIsAppendedAfterASilence() throws {
    let moonshine = try #require(LocalCatalog.model(LocalCatalog.moonshineBase)?.sherpa)
    let short = quietVoice(20) + silence10
    let longer = short + loudVoice(5)
    #expect(SpeechGate.hasSpeech(short) && SpeechGate.hasSpeech(longer))

    for (name, samples) in [("30 s", short), ("35 s", longer)] {
        let pieces = Pieces()
        let text = try moonshine.transcribe(samples) { piece in
            pieces.starts.append(piece.startIndex)
            return piece.startIndex < 20 * rate ? "earlier words" : "later words"
        }
        // The 35 s recording is cut at 20.05 s: the first piece has no silence
        // of its own, which must not make its words noise.
        #expect(pieces.starts.first == 0, "\(name): the first piece was never heard")
        #expect(text.hasPrefix("earlier words"), "\(name): \(text)")
    }
}

@Test func theFirstPieceKeepsTheRecordingsOwnSpeechLevel() throws {
    let samples = quietVoice(20) + silence10 + loudVoice(5)
    let level = try #require(SpeechGate.threshold(for: samples))
    // Cut where the model's windows cut it.
    let first = Array(samples[0 ..< Int(20.05 * Double(rate))])
    #expect(SpeechGate.hasSpeech(first) == false, "on its own the piece looks like noise")
    #expect(SpeechGate.hasSpeech(first[...], above: level))
    // The silence between the speech has none.
    #expect(SpeechGate.hasSpeech(silence10[...], above: level) == false)
    #expect(SpeechGate.speechEnd(first[...], above: level).map { $0 > 19 * rate } == true)
}

@Test func aPieceThatCameBackEmptyIsRetriedUpToItsLastSoundAlsoForQuietWords() throws {
    let moonshine = try #require(LocalCatalog.model(LocalCatalog.moonshineBase)?.sherpa)
    let samples = quietVoice(20) + silence10 + loudVoice(5)
    let pieces = Pieces()
    var whole = 0
    let text = try moonshine.transcribe(samples) { piece in
        pieces.lengths.append(piece.count)
        if piece.startIndex == 0 && pieces.lengths.count == 1 { whole = piece.count }
        // Empty for the whole first piece, words for the same piece cut at its last sound.
        return piece.startIndex == 0 && piece.count == whole ? "" : "words"
    }
    #expect(text == "words words")
    // The first piece, the first piece again up to its last sound, the second piece.
    #expect(pieces.lengths.count == 3 && pieces.lengths[1] < pieces.lengths[0] && pieces.lengths[1] > 19 * rate)
}

// MARK: - Parakeet is heard in pieces too

@Test func parakeetIsHeardInLongPiecesAndNoCallGetsMoreThanItsEncoderTakes() throws {
    let parakeet = try #require(LocalCatalog.model(LocalCatalog.parakeetV3)?.sherpa)
    // 500 s of tone with a quiet tenth of a second every 100 s: 4 s above its
    // encoder's 400 s, which stopped the app.
    var samples = loudVoice(500)
    for second in stride(from: 100, to: 500, by: 100) {
        for index in second * rate ..< second * rate + rate / 10 { samples[index] = 0 }
    }
    let pieces = Pieces()
    _ = try parakeet.transcribe(samples) { piece in
        pieces.lengths.append(piece.count)
        return "words"
    }
    #expect(pieces.lengths.count >= 3)
    #expect(pieces.lengths.reduce(0, +) == samples.count)
    #expect(pieces.lengths.allSatisfy { $0 <= 240 * rate })
}

@Test func noCallToARecognizerIsEverGivenMoreThanItsEncoderTakes() throws {
    for id in LocalCatalog.all.filter({ $0.sherpa != nil }).map(\.id) {
        let sherpa = try #require(LocalCatalog.model(id)?.sherpa)
        #expect(sherpa.windowSeconds * rate <= SherpaModel.longestCall, "\(id)")
    }
    // Parakeet's encoder holds 5000 frames, 12.5 a second: 400 s.
    #expect(SherpaModel.longestCall < 400 * rate)
}

@Test func aWindowOfNothingStillMovesOn() {
    let pieces = QuietWindows.split([Float](repeating: 0.1, count: 50), longest: 0)
    #expect(pieces.count == 50 && pieces.allSatisfy { $0.count == 1 })
}

// MARK: - A long word comparison is bounded

@Test func aDictationTooLongToCheckKeepsTheTextWithoutThePrompt() {
    // The lining up needs a table of every word against every word: 800 MB at 9 000.
    let sentence = "Das ist ein ganz normaler Satz ohne besondere Wörter und er ist einfach lang genug zum Zählen."
    let long = Array(repeating: sentence, count: 4_500 / 16 + 1).joined(separator: " ")
    #expect(WordCheck.words(long).count * WordCheck.words(long).count > WordCheck.largestComparison)
    #expect(WordCheck.keepEveryWord(prompted: long, plain: long) == (long, false))
}

@Test func aDictationOfTwentyMinutesIsStillChecked() {
    let sentence = "Das ist ein ganz normaler Satz ohne besondere Wörter und er ist einfach lang genug zum Zählen."
    let twenty = Array(repeating: sentence, count: 3_000 / 16).joined(separator: " ")
    #expect(WordCheck.keepEveryWord(prompted: twenty, plain: twenty).usedPrompt)
    // A dropped sentence is still found.
    let dropped = Array(repeating: sentence, count: 3_000 / 16 - 1).joined(separator: " ")
    #expect(WordCheck.keepEveryWord(prompted: dropped, plain: twenty).usedPrompt == false)
}

// MARK: - LE-04: Apple's language pack and the test mode

@Test func aTestCopyNeverInstallsAnythingAndOnlyTheUsersOwnSatzInstallsApples() {
    let own = LaunchMode.normal
    let shared = LaunchMode.test(stateFile: "/s/state.json", modelsFolder: nil)
    let scratch = LaunchMode.test(stateFile: "/s/state.json", modelsFolder: "/s/models")
    let invalid = LaunchMode.invalid("x")
    for id in [LocalCatalog.parakeetV3, LocalCatalog.turbo, LocalCatalog.moonshineTiny] {
        #expect(LocalCatalog.mayDownload(id, in: own))
        // A scratch folder is enough for files that go into it.
        #expect(LocalCatalog.mayDownload(id, in: scratch))
        #expect(!LocalCatalog.mayDownload(id, in: shared) && !LocalCatalog.mayDownload(id, in: invalid))
    }
    // Apple's goes into macOS's own store, which no folder moves.
    #expect(LocalCatalog.mayDownload(LocalCatalog.apple, in: own))
    #expect(!LocalCatalog.mayDownload(LocalCatalog.apple, in: scratch))
    #expect(!LocalCatalog.mayDownload(LocalCatalog.apple, in: shared))
    #expect(!LocalCatalog.mayDownload(LocalCatalog.apple, in: invalid))
}

// MARK: - LE-03: pinned commits and checksums

@Test func everySherpaFileHasAChecksumAndEveryModelACommit() throws {
    for id in LocalCatalog.all.filter({ $0.sherpa != nil }).map(\.id) {
        let sherpa = try #require(LocalCatalog.model(id)?.sherpa)
        #expect(sherpa.revision.count == 40 && sherpa.revision.allSatisfy(\.isHexDigit), "\(id) revision")
        #expect(!sherpa.owner.isEmpty && !sherpa.owner.contains("/"), "\(id) owner")
        for file in sherpa.files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(id) \(file.name)")
            #expect(sherpa.url(of: file).path.contains("/\(sherpa.owner)/\(sherpa.repo)/resolve/\(sherpa.revision)/"), "\(id) \(file.name)")
        }
    }
}

/// The Mac and Windows/Linux fetch the same files: what the Mac pins is what
/// desktop/src/core/localModels.ts pins. One side changed alone would make
/// one platform fetch another version.
@Test func theMacPinsTheCommitsAndChecksumsTheDesktopPins() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("desktop/src/core/localModels.ts"), encoding: .utf8)
    let repos = text.matches(of: /owner: '([^']+)', repo: '([^']+)', revision: '([0-9a-f]{40})'/)
    let macModels = LocalCatalog.all.compactMap(\.sherpa)
    #expect(repos.count == macModels.count, "localModels.ts and the Mac catalog do not offer the same sherpa-onnx models (\(repos.count) and \(macModels.count)), or localModels.ts changed shape")
    for (index, repo) in repos.enumerated() {
        let end = index + 1 < repos.count ? repos[index + 1].range.lowerBound : text.endIndex
        let block = text[repo.range.upperBound ..< end]
        let desktop = block.matches(of: /name: '([^']+)', role: '[^']+', bytes: ([0-9_]+), sha256: '([0-9a-f]{64})'/)
            .map { ($0.output.1, Int64($0.output.2.replacingOccurrences(of: "_", with: ""))!, $0.output.3) }
        let mac = try #require(macModels.first { $0.repo == repo.output.2 }, "\(repo.output.2) is not in the Mac catalog")
        #expect(mac.owner == String(repo.output.1), "\(mac.repo) owner")
        #expect(mac.revision == String(repo.output.3), "\(mac.repo) revision")
        // The window the models are heard in, where localModels.ts names it.
        if let window = block.firstMatch(of: /window: ([0-9]+)/) {
            #expect(mac.windowSeconds == Int(window.output.1), "\(mac.repo) window")
        }
        #expect(mac.files.count == desktop.count, "\(mac.repo) files")
        for (file, other) in zip(mac.files, desktop) {
            #expect(file.name == other.0 && file.bytes == other.1 && file.sha256 == String(other.2), "\(mac.repo) \(file.name)")
        }
    }
}

@Test func aChecksumIsTheSHA256OfTheBytes() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("satz-sha-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("abc".utf8).write(to: file)
    #expect(try FileDownload.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    // Over several pieces, as a 650 MB encoder is read.
    let big = Data((0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try big.write(to: file)
    #expect(try FileDownload.sha256(of: file) == sha256Hex(big))
    #expect(throws: CancellationError.self) { try FileDownload.sha256(of: file, isCancelled: { true }) }
}

/// Answers each request from a table by the file's name, and counts them.
private final class PinnedFiles: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        let body = Self.bodies[url.lastPathComponent]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func download() -> FileDownload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PinnedFiles.self]
        return FileDownload(progress: { _ in }, configuration: configuration)
    }
}

private let goodModel = Data(repeating: 1, count: 4_000)
private let goodTokens = Data("a 0\nb 1\n".utf8)
private let pinned = SherpaModel(kind: .senseVoice, repo: "satz-test", revision: String(repeating: "a", count: 40), files: [
    .init("model.int8.onnx", Int64(goodModel.count), sha256: sha256Hex(goodModel)),
    .init("tokens.txt", Int64(goodTokens.count), sha256: sha256Hex(goodTokens)),
])

private func scratchFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("satz-test-\(UUID().uuidString)", isDirectory: true)
}

@Suite(.serialized)
struct PinnedDownloadTests {
    @Test func coreMLDownloadKeepsNestedPathsAndRejectsDamagedWeights() async throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SherpaModel.File("Encoder.mlmodelc/weights/weight.bin", Int64(goodModel.count), sha256: sha256Hex(goodModel))
        let base = URL(string: "https://huggingface.co/FluidInference/parakeet-ultra-coreml/resolve/pinned/")!
        PinnedFiles.bodies = ["weight.bin": goodModel]
        PinnedFiles.requested = []
        try await PinnedFiles.download().run(files: [file], from: { base.appendingPathComponent($0.name) }, into: folder)
        let destination = folder.appendingPathComponent(file.name)
        #expect(try Data(contentsOf: destination) == goodModel)
        #expect(PinnedFiles.requested.map(\.path) == ["/FluidInference/parakeet-ultra-coreml/resolve/pinned/Encoder.mlmodelc/weights/weight.bin"])
        var damaged = goodModel
        damaged[0] ^= 0xff
        try damaged.write(to: destination)
        PinnedFiles.bodies = ["weight.bin": damaged]
        await #expect(throws: FileDownload.Failure.self) {
            try await PinnedFiles.download().run(files: [file], from: { base.appendingPathComponent($0.name) }, into: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func bytesOfTheRightSizeAndAnotherChecksumAreRefusedAndLeaveNothing() async throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var damaged = goodModel
        damaged[0] ^= 0xFF
        PinnedFiles.bodies = ["model.int8.onnx": damaged, "tokens.txt": goodTokens]
        PinnedFiles.requested = []
        await #expect(throws: FileDownload.Failure.self) { try await PinnedFiles.download().run(pinned, into: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.int8.onnx").path))
        // The first file stopped it: the second was not even asked for.
        #expect(PinnedFiles.requested.count == 1)
    }

    @Test func theRightBytesAreKeptAndFetchedFromThePinnedCommit() async throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        PinnedFiles.bodies = ["model.int8.onnx": goodModel, "tokens.txt": goodTokens]
        PinnedFiles.requested = []
        try await PinnedFiles.download().run(pinned, into: folder)
        #expect(try Data(contentsOf: folder.appendingPathComponent("model.int8.onnx")) == goodModel)
        #expect(try Data(contentsOf: folder.appendingPathComponent("tokens.txt")) == goodTokens)
        #expect(PinnedFiles.requested.map(\.absoluteString) == [
            "https://huggingface.co/csukuangfj/satz-test/resolve/\(pinned.revision)/model.int8.onnx",
            "https://huggingface.co/csukuangfj/satz-test/resolve/\(pinned.revision)/tokens.txt",
        ])
    }

    @Test func aFileThereAtTheRightSizeButOtherBytesIsReplaced() async throws {
        // What a model cached before checksums, or a bit that rotted, looks like.
        let folder = scratchFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var damaged = goodModel
        damaged[100] ^= 0x01
        try damaged.write(to: folder.appendingPathComponent("model.int8.onnx"))
        try goodTokens.write(to: folder.appendingPathComponent("tokens.txt"))
        PinnedFiles.bodies = ["model.int8.onnx": goodModel, "tokens.txt": goodTokens]
        PinnedFiles.requested = []
        try await PinnedFiles.download().run(pinned, into: folder)
        #expect(try Data(contentsOf: folder.appendingPathComponent("model.int8.onnx")) == goodModel)
        // The good file next to it was kept, not fetched again.
        #expect(PinnedFiles.requested.map(\.lastPathComponent) == ["model.int8.onnx"])
    }

    @Test func aFileThatCouldNotBeRefetchedLeavesNoDamagedOneBehind() async throws {
        let folder = scratchFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var damaged = goodModel
        damaged[7] ^= 0x01
        try damaged.write(to: folder.appendingPathComponent("model.int8.onnx"))
        PinnedFiles.bodies = [:]
        PinnedFiles.requested = []
        await #expect(throws: FileDownload.Failure.self) { try await PinnedFiles.download().run(pinned, into: folder) }
        // Offline, the damaged file must not be taken for the model the next time.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.int8.onnx").path))
    }
}

// MARK: - A model that cannot be read must not take satz with it

private func folderOf(_ model: SherpaModel, damaging damaged: String? = nil) throws -> URL {
    let folder = scratchFolder()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in model.files where file.name != damaged {
        try Data(count: Int(file.bytes)).write(to: folder.appendingPathComponent(file.name))
    }
    if let damaged {
        // Present, but cut short: what a zero-length or truncated file is.
        try Data().write(to: folder.appendingPathComponent(damaged))
    }
    return folder
}

private let tiny = SherpaModel(kind: .senseVoice, repo: "satz-test", revision: String(repeating: "b", count: 40), files: [
    .init("model.int8.onnx", 64, sha256: sha256Hex(Data(count: 64))), .init("tokens.txt", 8, sha256: sha256Hex(Data(count: 8))),
])

@Test func aModelWhoseFileIsMissingOrTheWrongSizeIsNotHandedToTheLoader() throws {
    let folder = try folderOf(tiny, damaging: "model.int8.onnx")
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(tiny.damagedFiles(in: folder).map(\.name) == ["model.int8.onnx"])
    var created = false
    #expect(throws: SherpaModel.Failure.damaged("model.int8.onnx")) {
        try tiny.load(from: folder) { _ in created = true; return 1 }
    }
    #expect(!created, "the loader that cannot survive this file was called")
    // A load that did not start leaves no mark: the model is not blamed for satz ending.
    #expect(!LoadMark(folder: folder).isSet)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("tokens.txt"))
    #expect(Set(tiny.damagedFiles(in: folder).map(\.name)) == ["model.int8.onnx", "tokens.txt"])
}

@Test func aFileOfTheRightSizeAndOtherBytesIsNotHandedToTheLoaderEither() throws {
    // The case that ended satz: a first bit flipped, the size as it was.
    let folder = try folderOf(tiny)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = folder.appendingPathComponent("model.int8.onnx")
    var bytes = try Data(contentsOf: model)
    bytes[0] = 0x08
    try bytes.write(to: model)
    // The sizes alone find nothing; the checksum does.
    #expect(tiny.damagedFiles(in: folder).isEmpty)
    #expect(tiny.damagedFiles(in: folder, checkingBytes: true).map(\.name) == ["model.int8.onnx"])
    var created = false
    #expect(throws: SherpaModel.Failure.damaged("model.int8.onnx")) {
        try tiny.load(from: folder) { _ in created = true; return 1 }
    }
    #expect(!created && !LoadMark(folder: folder).isSet)
}

@Test func aMarkStandsForAsLongAsTheLoadTakesAndGoesWhenItReturnsOrThrows() throws {
    let folder = try folderOf(tiny)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mark = LoadMark(folder: folder)
    #expect(!mark.isSet)
    var markedDuringLoad = false
    let value = try tiny.load(from: folder) { settings in
        markedDuringLoad = mark.isSet
        #expect(settings.senseVoice?.model == folder.appendingPathComponent("model.int8.onnx").path)
        return 42
    }
    #expect(value == 42 && markedDuringLoad)
    #expect(!mark.isSet)

    struct Refused: Error {}
    var markedWhenRefused = false
    #expect(throws: Refused.self) {
        try tiny.load(from: folder) { _ in markedWhenRefused = mark.isSet; throw Refused() } as Int
    }
    // sherpa-onnx answering "no" is handled, not a reason to blame the model at the next start.
    #expect(markedWhenRefused && !mark.isSet)
}

@Test func aLoadThatEndedSatzLeavesItsMarkForTheNextStart() throws {
    let folder = try folderOf(tiny)
    defer { try? FileManager.default.removeItem(at: folder) }
    // What is left on disk when the process ends inside `create`.
    let mark = LoadMark(folder: folder)
    mark.set()
    #expect(LoadMark(folder: folder).isSet)
    // Deleting the model takes it along, and so does downloading anew (which clears it).
    mark.clear()
    #expect(!LoadMark(folder: folder).isSet)
}

@Test func aTestCopyOnTheUsersOwnModelsWritesNoMarkIntoThem() throws {
    let folder = try folderOf(tiny)
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try tiny.load(from: folder, marking: false) { _ in
        #expect(!LoadMark(folder: folder).isSet)
        return 0
    }
}

@Test func theReasonsAreShortAndNameTheFile() {
    // In the app's language as it is: a test that switched the global language would race the others.
    let texts = [SherpaModel.Failure.damaged("model.int8.onnx"), .endedWhileLoading, .pieceNotHeard].map { $0.localizedDescription }
    #expect(texts.allSatisfy { !$0.isEmpty && !$0.contains("\u{2014}") && $0.count < 120 })
    #expect(texts[0].contains("model.int8.onnx"))
    #expect(FileDownload.Failure.damaged("x").localizedDescription.contains("x"))
}
