import Foundation

/// A model that runs through sherpa-onnx (k2-fsa, Apache-2.0) instead of
/// WhisperKit: Parakeet, Canary, Moonshine and SenseVoice, the ones Handy
/// offers. Each comes as single files from csukuangfj's repositories on
/// Hugging Face, the same exports sherpa-onnx's own examples use.
public struct SherpaModel: Hashable, Sendable {

    /// Which of sherpa-onnx's offline recognizers reads the files.
    public enum Kind: String, Hashable, Sendable {
        /// NVIDIA's Parakeet TDT: encoder, decoder and joiner.
        case nemoTransducer
        /// NVIDIA's Canary: told the language it hears.
        case canary
        /// Useful Sensors' Moonshine: four graphs, English only.
        case moonshine
        /// FunAudioLLM's SenseVoice: one graph, finds the language itself.
        case senseVoice
    }

    public struct File: Hashable, Sendable {
        public let name: String
        /// From huggingface.co/api/models/csukuangfj/<repo>/tree/main
        /// (09.10.2026): a download of another size is not this file.
        public let bytes: Int64

        public init(_ name: String, _ bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }
    }

    public let kind: Kind
    /// The repository under huggingface.co/csukuangfj.
    public let repo: String
    public let files: [File]

    public var bytes: Int64 { files.map(\.bytes).reduce(0, +) }

    public func url(of file: File) -> URL {
        URL(string: "https://huggingface.co/csukuangfj/\(repo)/resolve/main/\(file.name)")!
    }

    /// Heard 30 s at a time, cut at quiet moments (`QuietWindows`): Moonshine,
    /// SenseVoice and Canary were trained on short clips and lose words past
    /// that. Parakeet takes a whole dictation in one go.
    public var hearsInWindows: Bool { kind != .nemoTransducer }

    /// Listens for one language, the one satz is spoken to in.
    public var isToldTheLanguage: Bool { kind == .canary }

    /// Canary is given a second of silence after each piece of audio: cut
    /// off right after the last word, it dropped it ("ohne Gutschriften"
    /// came back as "Ohne"), and with the second it kept it every time.
    /// Not Parakeet: after a word cut off mid-way, silence made it write
    /// nothing at all.
    public var padsEnd: Bool { kind == .canary }

    public static func padded(_ samples: ArraySlice<Float>, sampleRate: Int = 16_000) -> [Float] {
        Array(samples) + [Float](repeating: 0, count: sampleRate)
    }

    /// The text as satz writes it: Canary puts a space before every comma
    /// and full stop ("Funktion , die ... liest .").
    public static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// A piece with speech in it came back empty, even on the second try.
        case pieceNotHeard

        public var errorDescription: String? {
            de("Ein Teil der Aufnahme kam leer zurück.", en: "Part of the recording came back empty.")
        }
    }

    /// A whole recording through `decode`, one recognizer call per piece:
    /// one piece for Parakeet, 30 s pieces cut at quiet moments for the
    /// others, silence never sent. A piece that comes back empty is tried
    /// once more up to its last sound (Parakeet wrote nothing for speech
    /// cut off mid-word and followed by quiet). One still empty throws:
    /// the other pieces' text would stand for the whole recording, and the
    /// lost words would never be asked for again. Cancelled (the dictation
    /// was thrown away or replaced), it stops before the next call.
    public func transcribe(_ samples: [Float], decode: (ArraySlice<Float>) throws -> String) throws -> String {
        // Silence is never sent: these models make something up for it too.
        guard SpeechGate.hasSpeech(samples) else { return "" }
        let pieces = hearsInWindows ? QuietWindows.split(samples) : [samples[...]]
        var said: [String] = []
        for piece in pieces {
            // The recording as a whole has speech; a quiet piece of it is skipped.
            guard pieces.count == 1 || SpeechGate.hasSpeech(Array(piece)) else { continue }
            try Task.checkCancellation()
            var heard = try decode(padsEnd ? Self.padded(piece)[...] : piece)
            if heard.isEmpty, let end = SpeechGate.speechEnd(Array(piece)), end < piece.count {
                try Task.checkCancellation()
                heard = try decode(piece.prefix(end))
            }
            guard !heard.isEmpty else { throw Failure.pieceNotHeard }
            said.append(heard)
        }
        return Self.tidy(said.joined(separator: " "))
    }

    /// What sherpa-onnx is given to load this model from `folder`.
    /// - Parameters:
    ///   - spoken: the language set in Settings, for a model that is told it.
    ///   - told: the language Canary is told instead (`LocalCatalog.Model.told`).
    ///   - threads: for ONNX Runtime; half the cores, at least two.
    public func settings(folder: URL, spoken: Language, told: String? = nil,
                         threads: Int = SherpaSettings.defaultThreads) -> SherpaSettings {
        let path = { (name: String) in folder.appendingPathComponent(name).path }
        var settings = SherpaSettings(tokens: path("tokens.txt"), threads: threads)
        switch kind {
        case .nemoTransducer:
            settings.modelType = "nemo_transducer"
            settings.transducer = .init(encoder: path(file("encoder")), decoder: path(file("decoder")), joiner: path(file("joiner")))
        case .canary:
            settings.canary = .init(encoder: path(file("encoder")), decoder: path(file("decoder")),
                                    language: told ?? spoken.rawValue, punctuation: true)
        case .moonshine:
            settings.moonshine = .init(preprocessor: path(file("preprocess")), encoder: path(file("encode")),
                                       uncachedDecoder: path(file("uncached_decode")), cachedDecoder: path(file("cached_decode")))
        case .senseVoice:
            settings.senseVoice = .init(model: path(file("model")), language: "auto", inverseNormalization: true)
        }
        return settings
    }

    /// The file whose name starts with `stem` and a dot ("encoder.int8.onnx").
    private func file(_ stem: String) -> String {
        files.first { $0.name.hasPrefix(stem + ".") }?.name ?? stem + ".onnx"
    }
}

/// sherpa-onnx's offline recognizer settings, as plain values: built and
/// tested here, copied into the C structs by the app.
public struct SherpaSettings: Equatable, Sendable {
    public struct Transducer: Equatable, Sendable {
        public var encoder, decoder, joiner: String
    }
    public struct Canary: Equatable, Sendable {
        public var encoder, decoder: String
        /// Heard and written in the same language: Canary also translates.
        public var language: String
        /// Punctuation and capitals.
        public var punctuation: Bool
    }
    public struct Moonshine: Equatable, Sendable {
        public var preprocessor, encoder, uncachedDecoder, cachedDecoder: String
    }
    public struct SenseVoice: Equatable, Sendable {
        public var model: String
        public var language: String
        /// Numbers as digits and punctuation, like the other models write.
        public var inverseNormalization: Bool
    }

    public var tokens: String
    public var threads: Int
    /// Only Parakeet needs it said; the others are told by their own section.
    public var modelType = ""
    public var transducer: Transducer?
    public var canary: Canary?
    public var moonshine: Moonshine?
    public var senseVoice: SenseVoice?
    /// satz records 16 kHz mono. Parakeet and Canary read their feature size
    /// from the model itself; 80 is SenseVoice's.
    public var sampleRate = 16_000
    public var featureDimension = 80
    public var decoding = "greedy_search"
    /// The processor: ONNX Runtime's Core ML provider is not used, so a model
    /// loads in seconds and runs the same on every Mac.
    public var provider = "cpu"

    public init(tokens: String, threads: Int) {
        self.tokens = tokens
        self.threads = threads
    }

    public static var defaultThreads: Int {
        min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}
