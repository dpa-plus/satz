import CoreML
import FluidAudio
import Foundation
import SatzKit

/// The entire recording goes to FluidAudio; its overlapping windows keep
/// long dictations intact. No language hint or translation is requested.
final class UltraRecognizer: Sendable {
    private let manager: AsrManager

    init(folder: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        // This entry point only reads our verified files. It cannot fall
        // back to downloading into FluidAudio's separate shared cache.
        let models = try AsrModels.loadLocal(from: folder, version: .ultra, configuration: configuration)
        manager = AsrManager()
        try await manager.loadModels(models)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard SpeechGate.hasSpeech(samples) else { return "" }
        // New state per dictation: words from the previous insertion must
        // never influence this one.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalModels.Failure.notUnderstood }
        return text
    }

    func unload() async { await manager.cleanup() }
}
