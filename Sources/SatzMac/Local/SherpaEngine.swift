import CSherpaOnnx
import Foundation
import SatzKit

/// One loaded sherpa-onnx model: Parakeet, Canary, Moonshine or SenseVoice,
/// through sherpa-onnx's C API on ONNX Runtime (Contents/Frameworks).
/// Used from one transcription at a time (LocalModels' queue), like WhisperKit.
final class SherpaRecognizer: @unchecked Sendable {

    enum Failure: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            de("Das Modell ließ sich nicht laden.", en: "The model could not be loaded.")
        }
    }

    private let recognizer: OpaquePointer
    private var settings: SherpaSettings

    /// Loads the model: a few seconds, so never on the main thread.
    init(_ settings: SherpaSettings) throws {
        self.settings = settings
        let made = Self.withConfig(settings) { SherpaOnnxCreateOfflineRecognizer($0) }
        // nil when sherpa-onnx finds the settings wrong, a file missing among them.
        guard let made else { throw Failure.notLoaded }
        recognizer = made
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Canary is told the language it hears, and changing it needs no reload.
    func listen(for language: String) {
        guard var canary = settings.canary, canary.language != language else { return }
        canary.language = language
        settings.canary = canary
        Self.withConfig(settings) { SherpaOnnxOfflineRecognizerSetConfig(recognizer, $0) }
    }

    /// - Parameter samples: 16 kHz mono.
    func transcribe(_ samples: ArraySlice<Float>) -> String {
        // Parakeet's encoder holds 400 s: one second more and ONNX Runtime
        // throws a C++ exception inside sherpa-onnx, which Swift cannot catch
        // and which ends satz with the whole recording in it. SherpaModel
        // hands over pieces of 240 s at most; this is the last line, for
        // anything longer that gets here whole. It is heard in pieces.
        guard samples.count > SherpaModel.longestCall else { return decode(samples) }
        Log.note(String(format: "local: %.0f s in one call, heard in pieces instead", Double(samples.count) / 16_000))
        return QuietWindows.split(Array(samples), longest: SherpaModel.longestCall).map(decode)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func decode(_ samples: ArraySlice<Float>) -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(settings.sampleRate), buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The C config for `settings`, valid only inside `body`: sherpa-onnx
    /// copies every string it is given, so they are freed right after.
    @discardableResult
    private static func withConfig<T>(_ settings: SherpaSettings, _ body: (UnsafePointer<SherpaOnnxOfflineRecognizerConfig>) -> T) -> T {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        let c = { (text: String) -> UnsafePointer<CChar> in
            let copy = strdup(text)!
            strings.append(copy)
            return UnsafePointer(copy)
        }
        // Every field zero to begin with: what sherpa-onnx takes as unset.
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(settings.sampleRate)
        config.feat_config.feature_dim = Int32(settings.featureDimension)
        config.decoding_method = c(settings.decoding)
        config.model_config.tokens = c(settings.tokens)
        config.model_config.num_threads = Int32(settings.threads)
        config.model_config.provider = c(settings.provider)
        config.model_config.debug = 0
        if !settings.modelType.isEmpty { config.model_config.model_type = c(settings.modelType) }
        if let transducer = settings.transducer {
            config.model_config.transducer.encoder = c(transducer.encoder)
            config.model_config.transducer.decoder = c(transducer.decoder)
            config.model_config.transducer.joiner = c(transducer.joiner)
        }
        if let canary = settings.canary {
            config.model_config.canary.encoder = c(canary.encoder)
            config.model_config.canary.decoder = c(canary.decoder)
            config.model_config.canary.src_lang = c(canary.language)
            config.model_config.canary.tgt_lang = c(canary.language)
            config.model_config.canary.use_pnc = canary.punctuation ? 1 : 0
        }
        if let moonshine = settings.moonshine {
            config.model_config.moonshine.preprocessor = c(moonshine.preprocessor)
            config.model_config.moonshine.encoder = c(moonshine.encoder)
            config.model_config.moonshine.uncached_decoder = c(moonshine.uncachedDecoder)
            config.model_config.moonshine.cached_decoder = c(moonshine.cachedDecoder)
        }
        if let senseVoice = settings.senseVoice {
            config.model_config.sense_voice.model = c(senseVoice.model)
            config.model_config.sense_voice.language = c(senseVoice.language)
            config.model_config.sense_voice.use_itn = senseVoice.inverseNormalization ? 1 : 0
        }
        return withUnsafePointer(to: &config) { body($0) }
    }

    /// The library's version, to log once it is loaded.
    static var version: String { String(cString: SherpaOnnxGetVersionStr()) }
}
