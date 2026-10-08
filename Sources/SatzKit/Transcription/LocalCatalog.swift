import Foundation

/// The models "Lokal" offers on a Mac: a short list to pick from, each with
/// its real download size. WhisperKit knows dozens of builds; these are the
/// ones that hear German and English and are worth the download.
public enum LocalCatalog {

    /// Today's default: Whisper Large v3 Turbo, compressed for the Neural
    /// Engine. The name says 632 MB; its files add up to 645.7 MB.
    public static let turbo = ModelCatalog.whisperTurbo
    /// The same model uncompressed: a little more accurate, 2.5 times the download.
    public static let turboFull = "openai_whisper-large-v3-v20240930_turbo"
    /// Argmax builds the two above only for M2 and newer; this one runs on
    /// every Apple chip, so an M1 gets it instead.
    public static let turboCompatible = "openai_whisper-large-v3-v20240930_626MB"
    /// Fast and small, but weak in German (49 % word errors where Whisper
    /// finds the language itself, as satz lets it).
    public static let small = "openai_whisper-small"
    public static let apple = ModelCatalog.apple

    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        /// What the download weighs, summed from the files in Argmax's
        /// repository (huggingface.co/api/models/argmaxinc/whisperkit-coreml,
        /// 08.10.2026). The tokenizer, about 2.5 MB, comes on top for all.
        /// nil for Apple's, which is part of macOS.
        public let bytes: Int64?

        public var isApple: Bool { id == LocalCatalog.apple }

        public var name: String {
            switch id {
            case LocalCatalog.turboFull: de("Whisper Large v3 Turbo, volle Größe", en: "Whisper Large v3 Turbo, full size")
            case LocalCatalog.turbo, LocalCatalog.turboCompatible: "Whisper Large v3 Turbo"
            case LocalCatalog.small: "Whisper Small"
            case LocalCatalog.apple: de("Apple Spracherkennung", en: "Apple speech recognition")
            default: id
            }
        }

        /// A quiet word after the name, where the name alone would mislead.
        public var tag: String? {
            id == LocalCatalog.small ? de("meist Englisch", en: "mostly English") : nil
        }
    }

    /// In the order shown: the default first, Apple's last.
    public static let all: [Model] = [
        Model(id: turbo, bytes: 645_668_913),
        Model(id: turboFull, bytes: 1_638_464_446),
        Model(id: turboCompatible, bytes: 626_718_238),
        Model(id: small, bytes: 486_487_465),
        Model(id: apple, bytes: nil),
    ]

    /// The Whisper builds, for the benchmark lookups.
    public static var whisperIDs: [String] { all.filter { !$0.isApple }.map(\.id) }

    public static func model(_ id: String) -> Model? {
        all.first { $0.id == id }
    }

    /// What this Mac is offered.
    /// - Parameters:
    ///   - supported: the builds Argmax supports on this chip, from WhisperKit's
    ///     support config. Its "default" is not used: for a chip it does not
    ///     know yet (an M5) it falls back to every model with Whisper Base,
    ///     the weakest, as the default.
    ///   - hasApple: macOS 26 or newer.
    public static func offered(supported: Set<String>, hasApple: Bool) -> [Model] {
        all.filter { model in
            switch model.id {
            case apple: hasApple
            // One Large v3 Turbo per Mac: the compatible build only where
            // the faster ones cannot run.
            case turboCompatible: supported.contains(turboCompatible) && !supported.contains(turbo)
            default: supported.contains(model.id)
            }
        }
    }

    /// The rows of the list, by id: what is offered, plus a hidden build
    /// that is on this Mac anyway (so it can be used or removed), plus the
    /// model in use when the list lacks it. The default is not added on a
    /// Mac that cannot run it: it was never picked there, only assumed.
    public static func rows(supported: Set<String>, hasApple: Bool, current: String, isOnMac: (String) -> Bool) -> [String] {
        let offered = Set(offered(supported: supported, hasApple: hasApple).map(\.id))
        var ids = all.map(\.id).filter { offered.contains($0) || ($0 != apple && isOnMac($0)) }
        if !ids.contains(current), !current.isEmpty, model(current) == nil || isOnMac(current) {
            ids.append(current)
        }
        return ids
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
