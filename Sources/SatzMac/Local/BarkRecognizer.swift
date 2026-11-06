import CoreML
import FluidAudio
import Foundation
import SatzKit

/// The publisher's CoreML pipeline: CPU frontend/decoder and ANE encoder.
/// Keep the 15-second function so FluidAudio can handle an entire recording,
/// including long dictations, with its own overlapping windows.
final class BarkRecognizer: Sendable {
    private let manager: AsrManager

    init(folder: URL, canCompile: Bool) async throws {
        #if !arch(arm64)
        throw Failure.needsAppleSilicon
        #else
        guard #available(macOS 15, *) else { throw Failure.needsMacOS15 }
        let cache = folder.appendingPathComponent("compiled-\(BarkAssets.revision)", isDirectory: true)
        func load(_ name: String, units: MLComputeUnits, function: String? = nil) throws -> MLModel {
            let destination = cache.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                // A test copy sharing the user's models must only read them.
                guard canCompile else { throw LocalModels.Failure.notDownloaded }
                try Task.checkCancellation()
                let compiled = try MLModel.compileModel(at: folder.appendingPathComponent("\(name).mlpackage"))
                defer { try? FileManager.default.removeItem(at: compiled) }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: compiled, to: destination)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            configuration.functionName = function
            return try MLModel(contentsOf: destination, configuration: configuration)
        }
        let raw = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: folder.appendingPathComponent("parakeet_v3_vocab.json")))
        let vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
        guard (0..<AsrModelVersion.ultra.blankId).allSatisfy({ vocabulary[$0] != nil }) else { throw Failure.vocabulary }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let models = try AsrModels(
            encoder: load("Encoder", units: .cpuAndNeuralEngine, function: "full15"),
            preprocessor: load("Preprocessor", units: .cpuOnly),
            decoder: load("Decoder", units: .cpuOnly),
            joint: load("JointDecisionv3", units: .cpuOnly),
            configuration: configuration, vocabulary: vocabulary, version: .ultra)
        manager = AsrManager(models: models)
        #endif
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard SpeechGate.hasSpeech(samples) else { return "" }
        // The reference runner pads the onset to protect the first word.
        let padded = Array(repeating: Float(0), count: 4_000) + samples
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(padded, decoderState: &state, language: nil)
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalModels.Failure.notUnderstood }
        return text
    }

    func unload() async { await manager.cleanup() }

    enum Failure: Error, LocalizedError {
        case needsAppleSilicon, needsMacOS15, vocabulary

        var errorDescription: String? {
            switch self {
            case .needsAppleSilicon: de("Bark 3.0 Pro braucht einen Mac mit Apple-Chip.", en: "Bark 3.0 Pro needs a Mac with Apple silicon.")
            case .needsMacOS15: de("Bark 3.0 Pro braucht macOS 15.", en: "Bark 3.0 Pro needs macOS 15.")
            case .vocabulary: de("Barks Wortdatei ist unvollständig. Lade das Modell erneut.", en: "Bark's vocabulary file is incomplete. Download the model again.")
            }
        }
    }
}
