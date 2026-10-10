import Foundation

/// A model that runs through sherpa-onnx (k2-fsa, Apache-2.0) instead of
/// WhisperKit: Parakeet, Canary, Moonshine and SenseVoice, the ones Handy
/// offers, and Cohere Transcribe and Qwen3-ASR. Each comes as single files
/// from a repository on Hugging Face: csukuangfj's, the same exports
/// sherpa-onnx's own examples use, csukuangfj2's for the newest, or the
/// author of a community export.
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
        /// Cohere Transcribe: encoder and decoder, told the language it hears
        /// (14 of them). Its encoder keeps its weights in a second file.
        case cohereTranscribe
        /// Qwen3-ASR: a conv frontend, an encoder and a decoder with a KV
        /// cache, a tokenizer folder; finds the language itself.
        case qwen3ASR
    }

    public struct File: Hashable, Sendable {
        public let name: String
        /// From huggingface.co/api/models/<owner>/<repo>/tree/<revision>
        /// (09.10.2026, the newer four 10.10.2026): a download of another size
        /// is not this file.
        public let bytes: Int64
        /// The file's SHA-256 at that revision (Hugging Face's LFS id; worked
        /// out for the small text files): the same size is not enough, one
        /// damaged file of the right size made the model loader abort satz.
        /// The values of desktop/src/core/localModels.ts.
        public let sha256: String

        public init(_ name: String, _ bytes: Int64, sha256: String) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public let kind: Kind
    /// Who the repository belongs to on Hugging Face: csukuangfj for the
    /// first exports, csukuangfj2 for the newest, a user's own for a
    /// community export.
    public let owner: String
    /// The repository under huggingface.co/<owner>.
    public let repo: String
    /// The commit the files are fetched from: on `main` they could change
    /// under their checksums, and every download would fail with them.
    public let revision: String
    public let files: [File]

    public init(kind: Kind, owner: String = "csukuangfj", repo: String, revision: String, files: [File]) {
        self.kind = kind
        self.owner = owner
        self.repo = repo
        self.revision = revision
        self.files = files
    }

    public var bytes: Int64 { files.map(\.bytes).reduce(0, +) }

    public func url(of file: File) -> URL {
        URL(string: "https://huggingface.co/\(owner)/\(repo)/resolve/\(revision)/\(file.name)")!
    }

    /// The longest piece one recognizer call is given, cut at quiet moments
    /// (`QuietWindows`): Moonshine, SenseVoice and Canary were trained on
    /// short clips and lose words past 30 s. Parakeet takes minutes, but its
    /// encoder holds 5000 frames, 400 s of audio: past that ONNX Runtime
    /// throws a C++ exception, which ends satz and the recording with it. A
    /// dictation under four minutes is still one piece. Cohere Transcribe
    /// takes 35 s a call; Qwen3-ASR's decoder holds the audio and the words
    /// together in a fixed length, so a longer piece loses its end
    /// (`qwen3WindowSeconds`).
    public var windowSeconds: Int {
        switch kind {
        case .nemoTransducer: 240
        case .qwen3ASR: Self.qwen3WindowSeconds
        default: 30
        }
    }

    /// No call is ever given more, whatever a window says: Parakeet's 400 s,
    /// less a margin.
    public static let longestCall = 380 * 16_000

    /// Listens for one language, the one satz is spoken to in.
    public var isToldTheLanguage: Bool { kind == .canary || kind == .cohereTranscribe }

    /// Writes text for steady noise (a fan, hiss), where Parakeet and Canary
    /// write nothing: Cohere Transcribe wrote whole German sentences for 12 s
    /// of hiss, Qwen3-ASR a line of Chinese for a steady rumble. Their pieces
    /// get one more check before they are heard (`SpeechGate.isSteady`).
    public var makesUpTextForNoise: Bool { kind == .cohereTranscribe || kind == .qwen3ASR }

    /// Takes the word list as a hint in its prompt (Qwen3-ASR's hotwords).
    public var takesHotwords: Bool { kind == .qwen3ASR }

    /// The word list as hotwords: one comma-separated string, which goes into
    /// the prompt in front of the audio, so a long list costs room and speed
    /// (sherpa-onnx warns past 48 tokens). A comma inside a word would split
    /// it; the first words are the ones the user added first. The same rule
    /// as desktop/src/main/sherpaEngine.ts.
    public static func hotwordList(_ vocabulary: [String]) -> String {
        var kept: [String] = []
        var length = 0
        for word in vocabulary {
            let clean = word.replacingOccurrences(of: #"[,\n]+"#, with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !clean.isEmpty else { continue }
            if kept.count >= 24 || length + clean.count > 240 { break }
            kept.append(clean)
            length += clean.count + 1
        }
        return kept.joined(separator: ",")
    }

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
        /// A file of the model is missing, or not the one pinned: another size or other bytes.
        case damaged(String)
        /// satz ended while it was loading this model, the time before.
        case endedWhileLoading

        public var errorDescription: String? {
            switch self {
            case .pieceNotHeard:
                de("Ein Teil der Aufnahme kam leer zurück.", en: "Part of the recording came back empty.")
            case .damaged(let file):
                de("\(file) fehlt oder ist beschädigt. Lösche das Modell und lade es neu herunter.",
                   en: "\(file) is missing or damaged. Delete the model and download it again.")
            case .endedWhileLoading:
                de("satz hat sich beim letzten Laden dieses Modells beendet. Lösche es oder lade es neu herunter.",
                   en: "satz quit the last time it loaded this model. Delete it or download it again.")
            }
        }
    }

    /// A whole recording through `decode`, one recognizer call per piece:
    /// 30 s pieces cut at quiet moments for most models, 240 s for Parakeet
    /// (`windowSeconds`), silence never sent. A piece that comes back empty
    /// is tried once more up to its last sound (Parakeet wrote nothing for
    /// speech cut off mid-word and followed by quiet). One still empty
    /// throws: the other pieces' text would stand for the whole recording,
    /// and the lost words would never be asked for again. Cancelled (the
    /// dictation was thrown away or replaced), it stops before the next call.
    public func transcribe(_ samples: [Float], decode: (ArraySlice<Float>) throws -> String) throws -> String {
        try transcribe(samples, hotwords: [], decode: { piece, _ in try decode(piece) })
    }

    /// The same, for models that take the word list: `decode` is given the
    /// hotwords (`hotwordList`, "" for none). The piece is heard plainly
    /// first; with a word list it is heard once more with it, and the hinted
    /// text is kept only if it lost no words (`WordCheck.keepEveryWord`):
    /// the same safeguard Whisper's prompt has.
    public func transcribe(_ samples: [Float], hotwords: [String],
                           decode: (ArraySlice<Float>, String) throws -> String) throws -> String {
        // Silence is never sent: these models make something up for it too.
        // And what counts as speech is worked out once, on the whole
        // recording, not again for each piece: a piece cut out with no
        // silence of its own (a quiet voice over a hum, then a pause and
        // more talking) read its own words as noise and was skipped.
        guard let level = SpeechGate.threshold(for: samples) else { return "" }
        let pieces = QuietWindows.split(samples, longest: min(windowSeconds * 16_000, Self.longestCall))
        let list = takesHotwords ? Self.hotwordList(hotwords) : ""
        var said: [String] = []
        for piece in pieces {
            // The recording as a whole has speech; a quiet piece of it is skipped.
            guard pieces.count == 1 || SpeechGate.hasSpeech(piece, above: level) else { continue }
            // A steady hum over the speech level: Cohere and Qwen3 write text for it.
            if makesUpTextForNoise, SpeechGate.isSteady(piece) { continue }
            try Task.checkCancellation()
            var heard = try decode(padsEnd ? Self.padded(piece)[...] : piece, "")
            if heard.isEmpty, let end = SpeechGate.speechEnd(piece, above: level), end < piece.count {
                try Task.checkCancellation()
                heard = try decode(piece.prefix(end), "")
            }
            guard !heard.isEmpty else { throw Failure.pieceNotHeard }
            if !list.isEmpty {
                try Task.checkCancellation()
                heard = WordCheck.keepEveryWord(prompted: try decode(piece, list), plain: heard).text
            }
            said.append(heard)
        }
        return Self.tidy(said.joined(separator: " "))
    }

    /// What sherpa-onnx is given to load this model from `folder`.
    /// - Parameters:
    ///   - spoken: the language set in Settings, for a model that is told it.
    ///     Canary is told the one it is to hear before each transcription
    ///     (`LocalCatalog.Model.told`), so this is only where it starts.
    ///   - threads: for ONNX Runtime; half the cores, at least two.
    public func settings(folder: URL, spoken: Language, threads: Int = SherpaSettings.defaultThreads) -> SherpaSettings {
        let path = { (name: String) in folder.appendingPathComponent(name).path }
        var settings = SherpaSettings(tokens: path("tokens.txt"), threads: threads)
        switch kind {
        case .nemoTransducer:
            settings.modelType = "nemo_transducer"
            settings.transducer = .init(encoder: path(file("encoder")), decoder: path(file("decoder")), joiner: path(file("joiner")))
        case .canary:
            settings.canary = .init(encoder: path(file("encoder")), decoder: path(file("decoder")),
                                    language: spoken.rawValue, punctuation: true)
        case .moonshine:
            settings.moonshine = .init(preprocessor: path(file("preprocess")), encoder: path(file("encode")),
                                       uncachedDecoder: path(file("uncached_decode")), cachedDecoder: path(file("cached_decode")))
        case .senseVoice:
            settings.senseVoice = .init(model: path(file("model")), language: "auto", inverseNormalization: true)
        case .cohereTranscribe:
            // Told before each transcription, like Canary; `spoken` is where it starts.
            settings.cohere = .init(encoder: path(file("encoder")), decoder: path(file("decoder")),
                                    language: spoken.rawValue, punctuation: true, inverseNormalization: true)
        case .qwen3ASR:
            // Its tokenizer is a folder and it has no tokens.txt.
            settings.tokens = ""
            settings.qwen3 = .init(convFrontend: path("conv_frontend.onnx"), encoder: path(file("encoder")), decoder: path(file("decoder")),
                                   tokenizer: path("tokenizer"), maxTotalLength: Self.qwen3MaxTotalLength,
                                   maxNewTokens: Self.qwen3MaxNewTokens)
        }
        return settings
    }

    /// What Qwen3-ASR is given to generate with. sherpa-onnx's C API leaves
    /// both at zero unless set, which it reads as "the model's own". Window
    /// and limits belong together: audio is 12.5 tokens a second, and the
    /// prompt, the audio and the new words all have to fit in the total.
    ///
    /// The decoder of this export holds 512 tokens in all (a longer total is
    /// cut to that): 40 s of audio is 500 tokens before a word is written,
    /// and came back as the single word "language". 15 s is 190 and leaves
    /// room for the words and a word list.
    public static let qwen3WindowSeconds = 15
    public static let qwen3MaxTotalLength = 512
    public static let qwen3MaxNewTokens = 160

    /// The files of this model that `folder` lacks or has changed: at another
    /// size, or with `checkingBytes` with another SHA-256. That reads every
    /// file, a third of a second for Parakeet's 650 MB.
    public func damagedFiles(in folder: URL, checkingBytes: Bool = false) -> [File] {
        files.filter { file in
            let url = folder.appendingPathComponent(file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard size == file.bytes else { return true }
            return checkingBytes && (try? FileDownload.sha256(of: url)) != file.sha256
        }
    }

    /// Loads the model from `folder` with `create` (sherpa-onnx's recognizer).
    /// sherpa-onnx does not survive a model file it cannot read: ONNX
    /// Runtime throws a C++ exception inside the C library, no Swift code can
    /// catch it, and satz ended at every start, as the model was loaded
    /// again. So a file that is not the one pinned (cut short, or damaged at
    /// its right size) is not handed over at all, and a `LoadMark` stands in
    /// the folder for as long as the load takes: found there at the next
    /// start, the load did not come back (a file the checksum cannot judge).
    /// - Parameter marking: false for a test copy that uses the user's own
    ///   models folder and must not write into it.
    public func load<Loaded>(from folder: URL, spoken: Language = .german, marking: Bool = true,
                             create: (SherpaSettings) throws -> Loaded) throws -> Loaded {
        if let broken = damagedFiles(in: folder, checkingBytes: true).first { throw Failure.damaged(broken.name) }
        let mark = LoadMark(folder: folder)
        if marking { mark.set() }
        // Not run when the process ends inside `create`: that is the point.
        defer { if marking { mark.clear() } }
        return try create(settings(folder: folder, spoken: spoken))
    }

    /// The file whose name starts with `stem` and a dot ("encoder.int8.onnx").
    /// Not the `.data` file beside an encoder that keeps its weights apart:
    /// that one is found by the encoder itself, under its own name.
    private func file(_ stem: String) -> String {
        files.first { $0.name.hasPrefix(stem + ".") && !$0.name.hasSuffix(".data") }?.name ?? stem + ".onnx"
    }
}

/// A file in a model's folder for as long as the model is being loaded. A
/// load that ends satz leaves it behind: the next start knows not to load
/// that model again and says why, so the user can delete or download it
/// again, instead of satz ending at every start. Only the Mac needs it:
/// Windows and Linux load sherpa-onnx in a helper process, where the same
/// exception only rejects the load.
public struct LoadMark: Sendable {
    public static let fileName = ".loading"
    private let url: URL

    public init(folder: URL) {
        url = folder.appendingPathComponent(Self.fileName)
    }

    public var isSet: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func set() {
        try? Data().write(to: url)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
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
    public struct Cohere: Equatable, Sendable {
        public var encoder, decoder: String
        /// The one language it hears and writes; it cannot find it itself.
        public var language: String
        /// Punctuation and capitals.
        public var punctuation: Bool
        /// Numbers as digits, like the other models write.
        public var inverseNormalization: Bool
    }
    public struct Qwen3: Equatable, Sendable {
        public var convFrontend, encoder, decoder: String
        /// The folder with vocab.json, merges.txt and tokenizer_config.json.
        public var tokenizer: String
        public var maxTotalLength: Int
        public var maxNewTokens: Int
    }

    public var tokens: String
    public var threads: Int
    /// Only Parakeet needs it said; the others are told by their own section.
    public var modelType = ""
    public var transducer: Transducer?
    public var canary: Canary?
    public var moonshine: Moonshine?
    public var senseVoice: SenseVoice?
    public var cohere: Cohere?
    public var qwen3: Qwen3?
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
