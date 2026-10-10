import Foundation

/// The models "Lokal" offers on a Mac, each with its real download size:
/// one build per Whisper size, from tiny and rough to large and slow, and
/// one for English only, through WhisperKit; Handy's models (Parakeet,
/// Canary, Moonshine, SenseVoice) through sherpa-onnx, with Cohere
/// Transcribe, Qwen3-ASR, Canary 1B v2 and a German Parakeet beside them;
/// and Apple's own. WhisperKit knows dozens more; the others are the same
/// models built differently, or English-only twins of these.
public enum LocalCatalog {

    /// Today's default: Whisper Large v3 Turbo, compressed for the Neural
    /// Engine. The name says 632 MB; its files add up to 645.7 MB.
    public static let turbo = ModelCatalog.whisperTurbo
    /// The same model uncompressed: a little more accurate, 2.5 times the download.
    public static let turboFull = "openai_whisper-large-v3-v20240930_turbo"
    /// Argmax builds the two above only for M2 and newer; this one runs on
    /// every Apple chip, so an M1 gets it instead.
    public static let turboCompatible = "openai_whisper-large-v3-v20240930_626MB"
    /// The original Large v3: 3.1 GB, a third of Turbo's speed.
    public static let largeV3 = "openai_whisper-large-v3"
    /// Distil-Whisper hears English only, fast. M2 and newer get Argmax's
    /// faster build, an M1 this one.
    public static let distil = "distil-whisper_distil-large-v3_turbo_600MB"
    public static let distilCompatible = "distil-whisper_distil-large-v3_594MB"
    /// Fast and small, but weak in German (49 % word errors where Whisper
    /// finds the language itself, as satz lets it).
    public static let small = "openai_whisper-small"
    /// Faster still, and rougher: 61 and 80 % word errors in German.
    public static let base = "openai_whisper-base"
    public static let tiny = "openai_whisper-tiny"
    public static let apple = ModelCatalog.apple

    // Through sherpa-onnx.
    public static let parakeetV3 = "parakeet-v3"
    public static let parakeetV2 = "parakeet-v2"
    public static let canary = "canary-180m"
    public static let cohere = "cohere-transcribe"
    public static let qwen3 = "qwen3-asr-0.6b"
    public static let canary1B = "canary-1b-v2"
    public static let parakeetGerman = "parakeet-primeline-de"
    public static let moonshineBase = "moonshine-base"
    public static let moonshineTiny = "moonshine-tiny"
    public static let senseVoice = "sense-voice"

    /// What runs a model.
    public enum Engine: Hashable, Sendable {
        case whisperKit
        case sherpa(SherpaModel)
        /// Apple's speech recognition, part of macOS 26.
        case apple
    }

    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        public let engine: Engine
        /// What the download weighs. For WhisperKit summed from the files in
        /// Argmax's repository (huggingface.co/api/models/argmaxinc/whisperkit-coreml,
        /// 08.10.2026), the tokenizer, about 2.5 MB, on top; for sherpa-onnx
        /// every file it fetches. nil for Apple's, which is part of macOS.
        public let bytes: Int64?
        /// The languages it hears.
        public let languages: LocalLanguages
        /// 0 to 1, higher is more accurate: Handy's scores for Handy's
        /// models, and in Handy's spirit for the others. A rough rating, not
        /// a measurement; the measured numbers are in the bar's help.
        public let accuracy: Double
        /// 0 to 1, higher is faster: only until the model is measured here
        /// or Argmax's numbers give an estimate (`LocalScores`).
        public let speed: Double

        init(_ id: String, engine: Engine = .whisperKit, bytes: Int64?, languages: LocalLanguages, accuracy: Double, speed: Double) {
            self.id = id
            self.engine = engine
            self.bytes = bytes
            self.languages = languages
            self.accuracy = accuracy
            self.speed = speed
        }

        public var isApple: Bool { engine == .apple }
        public var sherpa: SherpaModel? {
            if case .sherpa(let model) = engine { model } else { nil }
        }

        public var name: String {
            switch id {
            case LocalCatalog.turboFull: de("Whisper Large v3 Turbo, volle Größe", en: "Whisper Large v3 Turbo, full size")
            case LocalCatalog.turbo, LocalCatalog.turboCompatible: "Whisper Large v3 Turbo"
            case LocalCatalog.largeV3: "Whisper Large v3"
            case LocalCatalog.distil, LocalCatalog.distilCompatible: "Distil-Whisper Large v3"
            case LocalCatalog.small: "Whisper Small"
            case LocalCatalog.base: "Whisper Base"
            case LocalCatalog.tiny: "Whisper Tiny"
            case LocalCatalog.apple: de("Apple Spracherkennung", en: "Apple speech recognition")
            case LocalCatalog.parakeetV3: "Parakeet V3"
            case LocalCatalog.parakeetV2: "Parakeet V2"
            case LocalCatalog.canary: "Canary 180M Flash"
            case LocalCatalog.cohere: "Cohere Transcribe"
            case LocalCatalog.qwen3: "Qwen3-ASR 0.6B"
            case LocalCatalog.canary1B: "Canary 1B v2"
            case LocalCatalog.parakeetGerman: de("Parakeet Deutsch (primeLine)", en: "Parakeet German (primeLine)")
            case LocalCatalog.moonshineBase: "Moonshine Base"
            case LocalCatalog.moonshineTiny: "Moonshine Tiny"
            case LocalCatalog.senseVoice: "SenseVoice"
            default: id
            }
        }

        /// One plain sentence under the name: what the model is good for.
        public var summary: String {
            switch id {
            case LocalCatalog.turbo, LocalCatalog.turboCompatible: de("Ausgewogen: genau und schnell.", en: "Balanced: accurate and fast.")
            case LocalCatalog.turboFull: de("Etwas genauer, doppelt so groß.", en: "A little more accurate, twice the size.")
            case LocalCatalog.largeV3: de("Sehr genau, aber langsam.", en: "Very accurate, but slow.")
            case LocalCatalog.distil, LocalCatalog.distilCompatible: de("Schnell, nur Englisch.", en: "Fast, English only.")
            case LocalCatalog.small: de("Schnell, ordentlich auf Englisch.", en: "Fast, decent in English.")
            case LocalCatalog.base: de("Sehr schnell, ungenau.", en: "Very fast, rough.")
            case LocalCatalog.tiny: de("Am schnellsten, sehr ungenau.", en: "The fastest, very rough.")
            case LocalCatalog.apple: de("In macOS eingebaut, nichts zu laden.", en: "Built into macOS, nothing to download.")
            case LocalCatalog.parakeetV3: de("Schnell und genau. 25 europäische Sprachen.", en: "Fast and accurate. 25 European languages.")
            case LocalCatalog.parakeetV2: de("Nur Englisch, das beste für Englisch.", en: "English only. The best for English.")
            case LocalCatalog.canary: de("Sehr schnell. Englisch, Deutsch, Spanisch, Französisch.", en: "Very fast. English, German, Spanish, French.")
            case LocalCatalog.cohere: de("Am genauesten auf Deutsch, aber groß. Hört die Sprache, die du einstellst.",
                                         en: "The most accurate in German, but big. Hears the language you set.")
            case LocalCatalog.qwen3: de("Klein, findet die Sprache selbst und nimmt den Wortschatz als Hinweis. Auf Deutsch ungenauer als Parakeet.",
                                        en: "Small, finds the language itself and takes the word list as a hint. Less accurate in German than Parakeet.")
            case LocalCatalog.canary1B: de("Genau, aber groß. Englisch, Deutsch, Spanisch, Französisch.",
                                           en: "Accurate, but big. English, German, Spanish, French.")
            case LocalCatalog.parakeetGerman: de("Parakeet V3, auf Deutsch nachtrainiert. Schreibt „ss“ statt „ß“.",
                                                 en: "Parakeet V3, retrained for German. Writes “ss” for “ß”.")
            case LocalCatalog.moonshineBase: de("Sehr schnell, nur Englisch. Kommt gut mit Akzenten klar.", en: "Very fast, English only. Handles accents well.")
            case LocalCatalog.moonshineTiny: de("Extrem schnell, nur Englisch.", en: "Extremely fast, English only.")
            case LocalCatalog.senseVoice: de("Sehr schnell. Chinesisch, Englisch, Japanisch, Koreanisch, Kantonesisch.",
                                             en: "Very fast. Chinese, English, Japanese, Korean, Cantonese.")
            default: ""
            }
        }

        /// Who made it, for the model's name elsewhere in satz.
        public var maker: String {
            switch id {
            case LocalCatalog.apple: "Apple"
            case LocalCatalog.parakeetV3, LocalCatalog.parakeetV2, LocalCatalog.canary, LocalCatalog.canary1B: "NVIDIA"
            case LocalCatalog.cohere: "Cohere"
            case LocalCatalog.qwen3: "Qwen"
            case LocalCatalog.parakeetGerman: "primeLine"
            case LocalCatalog.moonshineBase, LocalCatalog.moonshineTiny: "Useful Sensors"
            case LocalCatalog.senseVoice: "FunAudioLLM"
            default: "OpenAI"
            }
        }

        /// Word errors someone else published for this model, never satz's
        /// own measurements: the Open ASR Leaderboard (Hugging Face, fetched
        /// 10.10.2026) for the first five, the model card's for primeLine.
        public var published: PublishedErrors? {
            switch id {
            case LocalCatalog.cohere: PublishedErrors(germanFleurs: 3.33, germanCommonVoice: 2.87, english: 6.26)
            case LocalCatalog.canary1B: PublishedErrors(germanFleurs: 3.43, germanCommonVoice: 4.69, english: 7.91)
            case LocalCatalog.qwen3: PublishedErrors(germanFleurs: 5.41, germanCommonVoice: 7.97, english: 6.60)
            case LocalCatalog.parakeetV3: PublishedErrors(germanFleurs: 4.16, germanCommonVoice: 4.07, english: 6.51)
            case LocalCatalog.parakeetV2: PublishedErrors(english: 6.43)
            // German average over its own tests, against V3's on the same.
            case LocalCatalog.parakeetGerman: PublishedErrors(makerGerman: 2.95, makerBaseline: 3.64)
            default: nil
            }
        }

        /// Hears English only: always decoded as English, never asked which
        /// language it heard (Whisper would answer English anyway, and translate).
        public var isEnglishOnly: Bool { languages.isEnglishOnly }

        /// The languages one can tell this model it hears, nil for a model
        /// that finds the language itself or hears one only. Canary hears
        /// and writes the one it is told: English, German, Spanish, French;
        /// Cohere Transcribe one of its 14.
        public var toldLanguages: [String]? { sherpa?.isToldTheLanguage == true ? languages.codes : nil }

        /// The language this model is told: the user's choice among its own,
        /// else the spoken language (German or English, which Whisper, the
        /// replacements and Apple's go by). nil for a model that is not told.
        public func told(choice: String?, spoken: Language) -> String? {
            guard let codes = toldLanguages else { return nil }
            if let choice, codes.contains(choice) { return choice }
            return spoken.rawValue
        }
    }

    private static func sherpa(_ kind: SherpaModel.Kind, owner: String = "csukuangfj", _ repo: String, revision: String,
                               _ files: [SherpaModel.File]) -> Engine {
        .sherpa(SherpaModel(kind: kind, owner: owner, repo: repo, revision: revision, files: files))
    }

    /// Whisper's 99, of which satz names the two it is spoken to in.
    private static let whisperLanguages = LocalLanguages(["de", "en"], count: 99)
    /// Parakeet V3's: 25 European languages, German and English among them.
    private static let european = LocalLanguages(["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                                                  "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"])

    /// Cohere Transcribe's 14, German and English first: the order of the list
    /// under "Gesprochen auf".
    private static let cohereLanguages = LocalLanguages(["de", "en", "fr", "es", "it", "pt", "nl", "pl", "el", "zh", "ja", "ko", "vi", "ar"])

    /// In the order shown: the default first, then the others that hear
    /// German, then English only, Apple's last.
    public static let all: [Model] = [
        Model(turbo, bytes: 645_668_913, languages: whisperLanguages, accuracy: 0.80, speed: 0.60),
        Model(turboFull, bytes: 1_638_464_446, languages: whisperLanguages, accuracy: 0.82, speed: 0.50),
        Model(turboCompatible, bytes: 626_718_238, languages: whisperLanguages, accuracy: 0.80, speed: 0.55),
        Model(largeV3, bytes: 3_090_319_899, languages: whisperLanguages, accuracy: 0.85, speed: 0.30),
        // Official sherpa-onnx export of Cohere's model (Apache-2.0). Its
        // encoder keeps its weights in the .data file beside it, which must
        // keep that name. Handy rates it 92; on the Open ASR Leaderboard it is
        // the best in German.
        Model(cohere, engine: sherpa(.cohereTranscribe, owner: "csukuangfj2", "sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01",
                                     revision: "156a470cf08eefe706a0004f3c52d9ee567ca7a0", [
            .init("encoder.int8.onnx", 3_090_822, sha256: "cf704f8cfa90e3f0a76f9ffc05998bdf00ba9ae983192c14a85a3a5eb008b367"),
            .init("encoder.int8.onnx.data", 2_731_503_072, sha256: "bcf1b7148c8518ae52df1ad2d2fc2b4e89261ea23e6c874eef1d9f55bcbaa4a3"),
            .init("decoder.int8.onnx", 153_250_705, sha256: "8372ca6c8ff4db8b916ca3592f5c757a715e691b9edec751ba19b29fc854baf9"),
            .init("tokens.txt", 207_437, sha256: "013ede043ae2480e3a9205cc34550d9686100cc682bacc90f702facdfbb93035"),
        ]), bytes: 2_888_052_036, languages: cohereLanguages, accuracy: 0.92, speed: 0.80),
        Model(parakeetV3, engine: sherpa(.nemoTransducer, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", revision: "2bda32ec70b097a55adaa07d9a7173915b43cc78", [
            .init("encoder.int8.onnx", 652_184_281, sha256: "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"),
            .init("decoder.int8.onnx", 11_845_275, sha256: "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"),
            .init("joiner.int8.onnx", 6_355_277, sha256: "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"),
            .init("tokens.txt", 93_939, sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
        ]), bytes: 670_478_772, languages: european, accuracy: 0.80, speed: 0.85),
        // x-ian's export of primeLine's German fine-tune of Parakeet V3
        // (CC-BY-4.0, upstream primeline/parakeet-primeline): its tokens file
        // is byte for byte V3's. A community upload, so pinned like the rest.
        Model(parakeetGerman, engine: sherpa(.nemoTransducer, owner: "x-ian", "sherpa-onnx-parakeet-primeline-de-int8",
                                             revision: "2a97df7e501bc25c6106a150a3379c5272088c53", [
            .init("encoder.int8.onnx", 652_282_298, sha256: "ecb67ffb98a12bf46eaf7657cb2f714f6569511817a831296325dd32bc4daa30"),
            .init("decoder.int8.onnx", 11_845_275, sha256: "fb4ddefe200706cabb27ee3fc1c81efa50555a4c8a8e00b663cc795216fb9369"),
            .init("joiner.int8.onnx", 6_355_277, sha256: "8220c0d117d81bdd0d8c770881932ac340f1ce4b36932941d561d11ad1aaffce"),
            .init("tokens.txt", 93_939, sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
        ]), bytes: 670_576_789, languages: .german, accuracy: 0.84, speed: 0.90),
        // Sarphix's export of NVIDIA's Canary 1B v2 (CC-BY-4.0). sherpa-onnx
        // 1.13.8 knows four of its 25 languages.
        Model(canary1B, engine: sherpa(.canary, owner: "Sarphix", "canary-1b-v2-sherpa-onnx-int8",
                                       revision: "7d513cd4f39f6c7dc75c13a284b5e345b37f6198", [
            .init("encoder.int8.onnx", 857_602_351, sha256: "0d8f349aaa015d47c81d88c4ba3a5461c19bc09ebb72bf4c61698eec9f09e968"),
            .init("decoder.int8.onnx", 558_682_707, sha256: "e68d839a8939a0c1d55d03fd5c6e6d3f113cfc97038027ffe566b8e3a4be2cd8"),
            .init("tokens.txt", 224_406, sha256: "399db68418b655f50275779cfe425c55a5ef6dda12cf38375d709566927ef513"),
        ]), bytes: 1_416_509_464, languages: LocalLanguages(["en", "de", "es", "fr"]), accuracy: 0.88, speed: 0.70),
        // Qwen's official sherpa-onnx export. Its value is size and finding
        // the language itself; the leaderboard has it behind Parakeet V3 in
        // German and level in English.
        Model(qwen3, engine: sherpa(.qwen3ASR, owner: "csukuangfj2", "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
                                    revision: "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a", [
            .init("conv_frontend.onnx", 44_148_281, sha256: "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e"),
            .init("encoder.int8.onnx", 182_491_662, sha256: "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9"),
            .init("decoder.int8.onnx", 755_914_231, sha256: "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771"),
            .init("tokenizer/vocab.json", 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            .init("tokenizer/merges.txt", 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            .init("tokenizer/tokenizer_config.json", 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        ]), bytes: 987_015_347, languages: LocalLanguages(["en", "de", "fr", "es", "it", "pt", "ru", "zh", "ja", "ko", "ar"], count: 30), accuracy: 0.76, speed: 0.62),
        Model(canary, engine: sherpa(.canary, "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8", revision: "9077164e0d3dd1d5353743e89ceaa1d3a770838c", [
            .init("encoder.int8.onnx", 132_678_643, sha256: "7a75b4e2a5857a6dcc0819503bbe3fad66943db4a3ccf21d3f27c633667d303f"),
            .init("decoder.int8.onnx", 74_437_848, sha256: "e41a2ab9c0c2fe81a1e8ade5a45fb02a74bc4db7d1f91b89a54a25e2cf79cba2"),
            .init("tokens.txt", 53_555, sha256: "2dae6fc7815f9640645e0c765522b278ee0cef49b482d91f6913e334628d3e77"),
        ]), bytes: 207_170_046, languages: LocalLanguages(["en", "de", "es", "fr"]), accuracy: 0.75, speed: 0.85),
        Model(distil, bytes: 607_114_331, languages: .english, accuracy: 0.75, speed: 0.70),
        Model(distilCompatible, bytes: 594_534_261, languages: .english, accuracy: 0.75, speed: 0.65),
        Model(parakeetV2, engine: sherpa(.nemoTransducer, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8", revision: "1ab9323565ddb038682214b292f588070a538ce2", [
            .init("encoder.int8.onnx", 652_184_296, sha256: "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab"),
            .init("decoder.int8.onnx", 7_257_753, sha256: "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e"),
            .init("joiner.int8.onnx", 1_739_080, sha256: "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2"),
            .init("tokens.txt", 9_384, sha256: "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d"),
        ]), bytes: 661_190_513, languages: .english, accuracy: 0.85, speed: 0.85),
        Model(moonshineBase, engine: sherpa(.moonshine, "sherpa-onnx-moonshine-base-en-int8", revision: "052b0798ad1bf046a140fdd4efcd9426530fa3f5", [
            .init("preprocess.onnx", 14_077_290, sha256: "ffa630d395c5ccf76f5d4954be5b882df76aaf6491519ec01fd82ea7a3819fb2"),
            .init("encode.int8.onnx", 50_311_494, sha256: "7e38770f776f2e5583a53b052936005df2ba5c833d7e09c2a5fd796b94bf73e2"),
            .init("uncached_decode.int8.onnx", 122_120_451, sha256: "c01f4b35093bcac20d352d23a75a539e772964579f9d024a90e5e6f09cae9987"),
            .init("cached_decode.int8.onnx", 99_983_837, sha256: "2db74e51cedf64a8b1be3c8192e0bb5e4923af0e90bd9e87f8e8771873f8ea03"),
            .init("tokens.txt", 436_688, sha256: "1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea"),
        ]), bytes: 286_929_760, languages: .english, accuracy: 0.70, speed: 0.90),
        Model(moonshineTiny, engine: sherpa(.moonshine, "sherpa-onnx-moonshine-tiny-en-int8", revision: "bf2b762c076d8ea61e2af0b3851c9564fb77552e", [
            .init("preprocess.onnx", 6_800_738, sha256: "f33addce61a143460fe753b5ee5b7db255e5140b5b779c065b94f6c83ff0bf4e"),
            .init("encode.int8.onnx", 18_249_187, sha256: "8774dfba578de027ec6595c2c654a0836434489bc963a0db124a7f181f571acb"),
            .init("uncached_decode.int8.onnx", 53_216_096, sha256: "216737000dd5881a17aa043f6bbd286add33e4c3b0ae257153e2ec15438bdc41"),
            .init("cached_decode.int8.onnx", 45_264_830, sha256: "2aff28bba6a03d8dcf5c9feac45462629bae37317442299f28115ad09da773f6"),
            .init("tokens.txt", 436_688, sha256: "1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea"),
        ]), bytes: 123_967_539, languages: .english, accuracy: 0.55, speed: 0.95),
        // FunAudioLLM's original SenseVoice Small. The newer "2025-09-09"
        // export is a Cantonese fine-tune (ASLP-lab's WSYue): on satz's
        // English clip it wrote "PNNYES ... BULLDOSZING THE GROOSSER", this
        // one "Pennies ... bulldozing the grocer".
        Model(senseVoice, engine: sherpa(.senseVoice, "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", revision: "2365baeacb507f821a0c8120fcee3d484dba7a07", [
            .init("model.int8.onnx", 239_233_841, sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
            .init("tokens.txt", 315_894, sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
        ]), bytes: 239_549_735, languages: LocalLanguages(["zh", "en", "ja", "ko", "yue"]), accuracy: 0.65, speed: 0.95),
        Model(small, bytes: 486_487_465, languages: whisperLanguages, accuracy: 0.60, speed: 0.80),
        Model(base, bytes: 146_719_453, languages: whisperLanguages, accuracy: 0.45, speed: 0.90),
        Model(tiny, bytes: 76_635_397, languages: whisperLanguages, accuracy: 0.35, speed: 0.95),
        Model(apple, engine: .apple, bytes: nil, languages: LocalLanguages(["de", "en"]), accuracy: 0.70, speed: 0.90),
    ]

    /// Whether a model may be downloaded in this launch mode. A test copy
    /// without a models folder of its own shares the user's models and never
    /// changes them. Apple's language pack is not in that folder at all: macOS
    /// keeps it in its own store, which `--models-dir` cannot move, so only
    /// the user's own satz installs it.
    public static func mayDownload(_ id: String, in mode: LaunchMode) -> Bool {
        guard mode.canChangeModels else { return false }
        return id != apple || mode == .normal
    }

    /// The Whisper builds, for the benchmark lookups.
    public static var whisperIDs: [String] { all.filter { $0.engine == .whisperKit }.map(\.id) }

    public static func model(_ id: String) -> Model? {
        all.first { $0.id == id }
    }

    /// What this Mac is offered.
    /// - Parameters:
    ///   - supported: the builds Argmax supports on this chip, from WhisperKit's
    ///     support config. Its "default" is not used: for a chip it does not
    ///     know yet (an M5) it falls back to every model with Whisper Base,
    ///     the weakest, as the default. sherpa-onnx's models run on every Mac.
    ///   - hasApple: macOS 26 or newer.
    public static func offered(supported: Set<String>, hasApple: Bool) -> [Model] {
        all.filter { model in
            switch model.id {
            case apple: hasApple
            // One Large v3 Turbo per Mac: the compatible build only where
            // the faster ones cannot run.
            case turboCompatible: supported.contains(turboCompatible) && !supported.contains(turbo)
            case distilCompatible: supported.contains(distilCompatible) && !supported.contains(distil)
            default: model.sherpa != nil || supported.contains(model.id)
            }
        }
    }

    /// The one marked "Recommended": the default, or on a Mac that cannot
    /// run it (an M1) the Turbo build that runs there.
    public static func recommended(supported: Set<String>) -> String {
        supported.contains(turbo) || !supported.contains(turboCompatible) ? turbo : turboCompatible
    }

    /// The cards, by id: what is offered, plus a hidden build that is on
    /// this Mac anyway (so it can be used or removed), plus the model in use
    /// when the list lacks it. The default is not added on a Mac that cannot
    /// run it: it was never picked there, only assumed.
    public static func rows(supported: Set<String>, hasApple: Bool, current: String, isOnMac: (String) -> Bool) -> [String] {
        let offered = Set(offered(supported: supported, hasApple: hasApple).map(\.id))
        var ids = all.map(\.id).filter { offered.contains($0) || ($0 != apple && isOnMac($0)) }
        if !ids.contains(current), !current.isEmpty, model(current) == nil || isOnMac(current) {
            ids.append(current)
        }
        return ids
    }

    /// "Your models" and "Available models", as Handy splits them: what is
    /// on this Mac (Apple's counts, it is part of macOS), the one in use
    /// first; and everything else, which downloads only when clicked.
    public static func sections(supported: Set<String>, hasApple: Bool, current: String,
                                isOnMac: (String) -> Bool) -> (yours: [String], available: [String]) {
        let ids = rows(supported: supported, hasApple: hasApple, current: current, isOnMac: isOnMac)
        let yours = ids.filter { $0 == apple || isOnMac($0) }
        return (yours.filter { $0 == current } + yours.filter { $0 != current }, ids.filter { !yours.contains($0) })
    }
}

/// What the Open ASR Leaderboard (or a model's maker) lists for a model, in
/// percent of wrong words: German on FLEURS and on Common Voice, English as
/// the average over its nine datasets.
public struct PublishedErrors: Hashable, Sendable {
    public var germanFleurs: Double?
    public var germanCommonVoice: Double?
    public var english: Double?
    /// A maker's own German average, and the base model's on the same test.
    public var makerGerman: Double?
    public var makerBaseline: Double?

    public init(germanFleurs: Double? = nil, germanCommonVoice: Double? = nil, english: Double? = nil,
                makerGerman: Double? = nil, makerBaseline: Double? = nil) {
        self.germanFleurs = germanFleurs
        self.germanCommonVoice = germanCommonVoice
        self.english = english
        self.makerGerman = makerGerman
        self.makerBaseline = makerBaseline
    }
}

/// The languages a model hears: the ones satz names, and how many in all.
public struct LocalLanguages: Hashable, Sendable {
    /// Language codes ("de"), in the order they are named.
    public let codes: [String]
    public let count: Int

    public init(_ codes: [String], count: Int? = nil) {
        self.codes = codes
        self.count = count ?? codes.count
    }

    public static let english = LocalLanguages(["en"])
    public static let german = LocalLanguages(["de"])

    public var hearsGerman: Bool { codes.contains("de") }
    public var isEnglishOnly: Bool { codes == ["en"] && count == 1 }

    /// "Nur Englisch", "Deutsch und Englisch", "Englisch, Deutsch, Spanisch,
    /// Französisch", "25 Sprachen": names up to four, a number above.
    public func text(language: Language = .current) -> String {
        let names = codes.map { Self.name($0, language: language) }
        let english = language == .english
        switch count {
        case 1: return english ? "\(names[0]) only" : "Nur \(names[0])"
        case 2 where names.count == 2: return names.joined(separator: english ? " and " : " und ")
        case 3 ... 4 where names.count == count: return names.joined(separator: ", ")
        default: return english ? "\(count) languages" : "\(count) Sprachen"
        }
    }

    /// Every language by name, for the help text; nil when satz names only
    /// some of them (Whisper's 99).
    public func list(language: Language = .current) -> String? {
        guard codes.count == count, count > 4 else { return nil }
        return codes.map { Self.name($0, language: language) }.joined(separator: ", ")
    }

    /// "Deutsch", "Kantonesisch": the language's name in the app's language.
    public static func name(_ code: String, language: Language = .current) -> String {
        let locale = Locale(identifier: language == .english ? "en" : "de")
        return locale.localizedString(forLanguageCode: code) ?? code
    }
}

/// The two bars on a model's card, from 0 to 1.
public enum LocalScores {

    /// Seconds per 10 s of speech on a log scale: 0.2 s or less is 1, 1 s
    /// 0.7, 3 s 0.4, 10 s or more 0.1, straight lines in between. A second
    /// more matters at 1 s and hardly at 10.
    public static func speed(secondsPer10: Double) -> Double {
        let points: [(seconds: Double, score: Double)] = [(0.2, 1.0), (1, 0.7), (3, 0.4), (10, 0.1)]
        guard secondsPer10 > points[0].seconds else { return points[0].score }
        for (low, high) in zip(points, points.dropFirst()) where secondsPer10 <= high.seconds {
            let along = log(secondsPer10 / low.seconds) / log(high.seconds / low.seconds)
            // Kept inside the ends, which rounding could step past by a hair.
            return max(points[points.count - 1].score, low.score + (high.score - low.score) * along)
        }
        return points[points.count - 1].score
    }

    /// Where the speed bar's number comes from.
    public enum SpeedSource: Equatable, Sendable {
        /// Timed on this Mac's chip.
        case measured(LocalSpeed)
        /// Argmax's measurement on the nearest chip, perhaps scaled by a
        /// model measured here.
        case estimated(secondsPer10: Double, chip: String, scaledBy: String?)
        /// Nothing known on this Mac: the model's fixed score.
        case rated
    }

    /// The speed bar: measured on this chip first, else Argmax's estimate,
    /// else the model's own score.
    public static func speed(of id: String, measured: [String: LocalSpeed], chip: String?,
                             benchmarks: LocalBenchmarks) -> (score: Double, source: SpeedSource) {
        if let speed = measured[id], speed.machine == (chip ?? speed.machine) {
            return (self.speed(secondsPer10: speed.secondsPer10), .measured(speed))
        }
        if let estimate = benchmarks.estimate(id, chip: chip, measured: measured) {
            return (self.speed(secondsPer10: estimate.secondsPer10),
                    .estimated(secondsPer10: estimate.secondsPer10, chip: estimate.chip, scaledBy: estimate.scaledBy))
        }
        return (LocalCatalog.model(id)?.speed ?? 0, .rated)
    }
}

/// The facts on a local model's second line, worded for the app's language.
/// Separate from the views so the numbers can be tested in both languages.
public enum LocalFacts {

    /// "646 MB", "1,6 GB" (German comma, English point): megabytes of a
    /// million bytes, as the download shows them.
    public static func size(_ bytes: Int64, language: Language = .current) -> String {
        let megabytes = (Double(bytes) / 1_000_000).rounded()
        if megabytes < 1000 { return "\(Int(megabytes)) MB" }
        return "\(number(Double(bytes) / 1_000_000_000, language: language)) GB"
    }

    /// "0,7 s für 10 s Sprechen", or "ca. 0,9 s …" for an estimate.
    public static func speed(_ secondsPer10: Double, estimated: Bool, language: Language = .current) -> String {
        let seconds = number(secondsPer10, language: language)
        return language == .english
            ? "\(estimated ? "about " : "")\(seconds) s per 10 s of speech"
            : "\(estimated ? "ca. " : "")\(seconds) s für 10 s Sprechen"
    }

    /// "6,9 % Fehler Englisch, 14,7 % Deutsch": only the languages that have
    /// a number; nil when neither has one.
    public static func errors(english: Double?, german: Double?, language: Language = .current) -> String? {
        let en = english.map { number($0, language: language) }
        let de = german.map { number($0, language: language) }
        if language == .english {
            switch (en, de) {
            case let (en?, de?): return "\(en) % errors in English, \(de) % in German"
            case let (en?, nil): return "\(en) % errors in English"
            case let (nil, de?): return "\(de) % errors in German"
            case (nil, nil): return nil
            }
        }
        switch (en, de) {
        case let (en?, de?): return "\(en) % Fehler Englisch, \(de) % Deutsch"
        case let (en?, nil): return "\(en) % Fehler Englisch"
        case let (nil, de?): return "\(de) % Fehler Deutsch"
        case (nil, nil): return nil
        }
    }

    /// "3,3 % wrong words in German on FLEURS, 2,9 % on Common Voice; 6,3 %
    /// in English on average. Open ASR Leaderboard, not measured by satz."
    /// For the accuracy bar's help.
    public static func published(_ errors: PublishedErrors, language: Language = .current) -> String {
        let english = language == .english
        var parts: [String] = []
        switch (errors.germanFleurs, errors.germanCommonVoice) {
        case let (fleurs?, voice?):
            let (f, v) = (number(fleurs, language: language), number(voice, language: language))
            parts.append(english ? "\(f) % wrong words in German on FLEURS, \(v) % on Common Voice"
                                 : "\(f) % falsche Wörter auf Deutsch (FLEURS), \(v) % (Common Voice)")
        case let (fleurs?, nil):
            let f = number(fleurs, language: language)
            parts.append(english ? "\(f) % wrong words in German on FLEURS" : "\(f) % falsche Wörter auf Deutsch (FLEURS)")
        default: break
        }
        if let value = errors.english {
            let e = number(value, language: language)
            parts.append(english ? "\(e) % in English on average" : "\(e) % auf Englisch im Schnitt")
        }
        if let value = errors.makerGerman {
            let m = number(value, language: language, decimals: 2)
            let base = errors.makerBaseline.map { number($0, language: language, decimals: 2) }
            parts.append(english ? "\(m) % wrong words in German on average" + (base.map { " (Parakeet V3: \($0) %)" } ?? "")
                                 : "\(m) % falsche Wörter auf Deutsch im Schnitt" + (base.map { " (Parakeet V3: \($0) %)" } ?? ""))
        }
        let source = errors.makerGerman != nil
            ? (english ? "The maker's own figures" : "Angaben des Herstellers")
            : "Open ASR Leaderboard"
        let tail = english ? "\(source), not measured by satz." : "\(source), nicht von satz gemessen."
        return parts.joined(separator: "; ") + ". " + tail
    }

    /// One decimal, never "0,0": a speed that small is still not nothing.
    public static func number(_ value: Double, language: Language = .current, decimals: Int = 1) -> String {
        let text = String(format: "%.\(decimals)f", max(value, pow(10, -Double(decimals))))
        return language == .english ? text : text.replacingOccurrences(of: ".", with: ",")
    }

    /// "8. Okt. 2026" / "Oct 8, 2026", for when a speed was measured.
    public static func date(_ date: Date, language: Language = .current) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year()
            .locale(Locale(identifier: language == .english ? "en_US" : "de_DE")))
    }
}

/// How fast a model ran here, measured on satz's own 10 s clip.
public struct LocalSpeed: Codable, Hashable, Sendable {
    /// Seconds of work for 10 seconds of speech: lower is faster.
    public let secondsPer10: Double
    public let measured: Date
    /// satz's version then. Kept with the number for the test mode's state
    /// file; the card shows any number with its date, as long as it is from
    /// this chip.
    public let version: String
    /// The chip, as macOS names it ("Apple M5 Pro"): a number restored onto
    /// another Mac is not this one's.
    public let machine: String

    public init(secondsPer10: Double, measured: Date, version: String, machine: String) {
        self.secondsPer10 = secondsPer10
        self.measured = measured
        self.version = version
        self.machine = machine
    }

    /// Wall time for a clip, scaled to 10 seconds of speech.
    public static func secondsPer10(elapsed: TimeInterval, clipSeconds: Double) -> Double {
        guard clipSeconds > 0 else { return 0 }
        return elapsed * 10 / clipSeconds
    }
}
