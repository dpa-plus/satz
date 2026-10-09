import Foundation

/// The models "Lokal" offers on a Mac, each with its real download size:
/// one build per Whisper size, from tiny and rough to large and slow, and
/// one for English only, through WhisperKit; Handy's models (Parakeet,
/// Canary, Moonshine, SenseVoice) through sherpa-onnx; and Apple's own.
/// WhisperKit knows dozens more; the others are the same models built
/// differently, or English-only twins of these.
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
            case LocalCatalog.parakeetV3, LocalCatalog.parakeetV2, LocalCatalog.canary: "NVIDIA"
            case LocalCatalog.moonshineBase, LocalCatalog.moonshineTiny: "Useful Sensors"
            case LocalCatalog.senseVoice: "FunAudioLLM"
            default: "OpenAI"
            }
        }

        /// Hears English only: always decoded as English, never asked which
        /// language it heard (Whisper would answer English anyway, and translate).
        public var isEnglishOnly: Bool { languages.isEnglishOnly }

        /// The languages one can tell this model it hears, nil for a model
        /// that finds the language itself or hears one only. Canary hears
        /// and writes the one it is told: English, German, Spanish, French.
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

    private static func sherpa(_ kind: SherpaModel.Kind, _ repo: String, _ files: [SherpaModel.File]) -> Engine {
        .sherpa(SherpaModel(kind: kind, repo: repo, files: files))
    }

    /// Whisper's 99, of which satz names the two it is spoken to in.
    private static let whisperLanguages = LocalLanguages(["de", "en"], count: 99)
    /// Parakeet V3's: 25 European languages, German and English among them.
    private static let european = LocalLanguages(["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                                                  "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"])

    /// In the order shown: the default first, then the others that hear
    /// German, then English only, Apple's last.
    public static let all: [Model] = [
        Model(turbo, bytes: 645_668_913, languages: whisperLanguages, accuracy: 0.80, speed: 0.60),
        Model(turboFull, bytes: 1_638_464_446, languages: whisperLanguages, accuracy: 0.82, speed: 0.50),
        Model(turboCompatible, bytes: 626_718_238, languages: whisperLanguages, accuracy: 0.80, speed: 0.55),
        Model(largeV3, bytes: 3_090_319_899, languages: whisperLanguages, accuracy: 0.85, speed: 0.30),
        Model(parakeetV3, engine: sherpa(.nemoTransducer, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", [
            .init("encoder.int8.onnx", 652_184_281), .init("decoder.int8.onnx", 11_845_275),
            .init("joiner.int8.onnx", 6_355_277), .init("tokens.txt", 93_939),
        ]), bytes: 670_478_772, languages: european, accuracy: 0.80, speed: 0.85),
        Model(canary, engine: sherpa(.canary, "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8", [
            .init("encoder.int8.onnx", 132_678_643), .init("decoder.int8.onnx", 74_437_848), .init("tokens.txt", 53_555),
        ]), bytes: 207_170_046, languages: LocalLanguages(["en", "de", "es", "fr"]), accuracy: 0.75, speed: 0.85),
        Model(distil, bytes: 607_114_331, languages: .english, accuracy: 0.75, speed: 0.70),
        Model(distilCompatible, bytes: 594_534_261, languages: .english, accuracy: 0.75, speed: 0.65),
        Model(parakeetV2, engine: sherpa(.nemoTransducer, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8", [
            .init("encoder.int8.onnx", 652_184_296), .init("decoder.int8.onnx", 7_257_753),
            .init("joiner.int8.onnx", 1_739_080), .init("tokens.txt", 9_384),
        ]), bytes: 661_190_513, languages: .english, accuracy: 0.85, speed: 0.85),
        Model(moonshineBase, engine: sherpa(.moonshine, "sherpa-onnx-moonshine-base-en-int8", [
            .init("preprocess.onnx", 14_077_290), .init("encode.int8.onnx", 50_311_494),
            .init("uncached_decode.int8.onnx", 122_120_451), .init("cached_decode.int8.onnx", 99_983_837),
            .init("tokens.txt", 436_688),
        ]), bytes: 286_929_760, languages: .english, accuracy: 0.70, speed: 0.90),
        Model(moonshineTiny, engine: sherpa(.moonshine, "sherpa-onnx-moonshine-tiny-en-int8", [
            .init("preprocess.onnx", 6_800_738), .init("encode.int8.onnx", 18_249_187),
            .init("uncached_decode.int8.onnx", 53_216_096), .init("cached_decode.int8.onnx", 45_264_830),
            .init("tokens.txt", 436_688),
        ]), bytes: 123_967_539, languages: .english, accuracy: 0.55, speed: 0.95),
        // FunAudioLLM's original SenseVoice Small. The newer "2025-09-09"
        // export is a Cantonese fine-tune (ASLP-lab's WSYue): on satz's
        // English clip it wrote "PNNYES ... BULLDOSZING THE GROOSSER", this
        // one "Pennies ... bulldozing the grocer".
        Model(senseVoice, engine: sherpa(.senseVoice, "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", [
            .init("model.int8.onnx", 239_233_841), .init("tokens.txt", 315_894),
        ]), bytes: 239_549_735, languages: LocalLanguages(["zh", "en", "ja", "ko", "yue"]), accuracy: 0.65, speed: 0.95),
        Model(small, bytes: 486_487_465, languages: whisperLanguages, accuracy: 0.60, speed: 0.80),
        Model(base, bytes: 146_719_453, languages: whisperLanguages, accuracy: 0.45, speed: 0.90),
        Model(tiny, bytes: 76_635_397, languages: whisperLanguages, accuracy: 0.35, speed: 0.95),
        Model(apple, engine: .apple, bytes: nil, languages: LocalLanguages(["de", "en"]), accuracy: 0.70, speed: 0.90),
    ]

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

    /// One decimal, never "0,0": a speed that small is still not nothing.
    public static func number(_ value: Double, language: Language = .current) -> String {
        let text = String(format: "%.1f", max(value, 0.1))
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
    /// satz's version then: an update can change how fast a model runs.
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

    /// Measured on this chip by this version of satz. Any other number still
    /// shows, with its date, and asks to be measured again. An unreadable
    /// chip counts as the same.
    public func isCurrent(chip: String?, version: String) -> Bool {
        machine == (chip ?? machine) && self.version == version
    }

    /// Wall time for a clip, scaled to 10 seconds of speech.
    public static func secondsPer10(elapsed: TimeInterval, clipSeconds: Double) -> Double {
        guard clipSeconds > 0 else { return 0 }
        return elapsed * 10 / clipSeconds
    }
}
