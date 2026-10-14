import Foundation

/// What cleaning up adds to a dictation: seconds of waiting and dollars, from
/// the catalog's measurements scaled to how long the user's dictations are,
/// or from what this computer measured.
public struct CleanupEstimate: Equatable, Sendable {
    /// Seconds added to each dictation; nil until measured where nothing is known.
    public let seconds: Double?
    /// Whether `seconds` was measured on this computer (at least two runs).
    public let measured: Bool
    /// Dollars per dictation and per hour of talking: 0 for free, nil unknown.
    public let dollarsPerDictation: Double?
    public let dollarsPerHour: Double?
    /// How long the typical dictation is, in seconds of talking.
    public let talkingSeconds: Double

    /// People say about 14 characters a second.
    public static let charactersPerSecond = 14.0
    /// Without history: about 30 seconds of talking.
    public static let standardCharacters = 400.0

    /// The median length of the last 50 dictations (what was said, before
    /// cleanup), once there are at least five; 400 characters before that.
    public static func typicalCharacters(_ lengths: [Int]) -> Double {
        let recent = Array(lengths.prefix(50))
        guard recent.count >= 5 else { return standardCharacters }
        return median(recent.map(Double.init)) ?? standardCharacters
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// - Parameters:
    ///   - characters: the typical dictation's length (`typicalCharacters`).
    ///   - measuredSeconds: this computer's median, once there are two runs.
    public init(model: CleanupModel, level: CleanupLevel, vocabulary: [String] = [], customPrompt: String = "",
                characters: Double, measuredSeconds: Double? = nil) {
        let messages = CleanupPrompt.messages(level, text: "", vocabulary: vocabulary, customPrompt: customPrompt)
        // The examples, and about 40 characters for the dictation's tags.
        let promptCharacters = CleanupTiming.characters(messages.system)
            + messages.turns.dropLast().map { CleanupTiming.characters($0.content) }.reduce(0, +) + 40
        let promptTokens = Double(CleanupTiming.tokens(promptCharacters))
        let textTokens = CleanupTiming.tokens(characters)
        let outTokens = textTokens * level.outputFactor
        let inTokens = promptTokens + textTokens
        talkingSeconds = characters / Self.charactersPerSecond
        if let priceIn = model.input, let priceOut = model.output {
            let perDictation = (inTokens * priceIn + outTokens * priceOut) / 1_000_000 * model.tokenFactor
            dollarsPerDictation = perDictation
            dollarsPerHour = perDictation * 3600 / talkingSeconds
        } else {
            dollarsPerDictation = nil
            dollarsPerHour = nil
        }
        if let measuredSeconds {
            seconds = measuredSeconds
            measured = true
        } else if let base = model.seconds, let rate = model.tokensPerSecond {
            // Never below 60 %: a short dictation still waits for the network.
            seconds = max(base * 0.6, base + (outTokens * model.tokenFactor - 80) / rate)
            measured = false
        } else {
            seconds = nil
            measured = false
        }
    }
}

// MARK: - Measured

/// The times and costs of real cleanups on this computer, per provider and
/// model: every dictation and every "Ausprobieren". The last 20 each.
public struct CleanupSpeeds: Codable, Equatable, Sendable {

    public struct Run: Codable, Equatable, Sendable {
        public let seconds: Double
        public let dollars: Double?
        public let date: Date
    }

    public private(set) var runs: [String: [Run]] = [:]

    public static let kept = 20

    public init() {}

    static func key(_ provider: CleanupProvider, _ model: String) -> String { "\(provider.rawValue)/\(model)" }

    public mutating func add(_ provider: CleanupProvider, model: String, seconds: Double, dollars: Double?, at date: Date = Date()) {
        var list = runs[Self.key(provider, model)] ?? []
        list.append(Run(seconds: seconds, dollars: dollars, date: date))
        runs[Self.key(provider, model)] = Array(list.suffix(Self.kept))
    }

    /// The median time, once there are at least two: one run may have loaded the model.
    public func seconds(_ provider: CleanupProvider, model: String) -> Double? {
        let list = runs[Self.key(provider, model)] ?? []
        guard list.count >= 2 else { return nil }
        return CleanupEstimate.median(list.map(\.seconds))
    }

    public func count(_ provider: CleanupProvider, model: String) -> Int {
        runs[Self.key(provider, model)]?.count ?? 0
    }
}

// MARK: - Wording

/// The estimate in words, for the model menu and the line under it.
public enum CleanupWording {

    static func locale(_ language: Language) -> Locale { Locale(identifier: language == .english ? "en_US" : "de_DE") }

    /// "+1,3 s" / "+1.3 s".
    public static func seconds(_ value: Double, in language: Language = .current) -> String {
        "+" + value.formatted(.number.precision(.fractionLength(1)).locale(locale(language))) + " s"
    }

    /// "0,01 $" / "$0.01". A plain space before the dollar sign in German,
    /// like the transcription's prices and like Windows and Linux: the
    /// locale's own currency format puts a no-break space there.
    public static func dollars(_ value: Double, in language: Language = .current) -> String {
        money(value, decimals: 2, in: language)
    }

    private static func money(_ value: Double, decimals: Int, in language: Language) -> String {
        let number = value.formatted(.number.precision(.fractionLength(decimals)).locale(locale(language)))
        return language == .english ? "$\(number)" : "\(number) $"
    }

    /// A single cleanup's cost, which is a fraction of a cent: "0,0002 $".
    /// Four decimals; "unter 0,0001 $" where they would all be zeros ("0 $"
    /// for what cost nothing); from a cent on, the usual two.
    public static func smallDollars(_ value: Double, in language: Language = .current) -> String {
        if value >= 0.01 { return dollars(value, in: language) }
        let english = language == .english
        if value <= 0 { return english ? "$0" : "0 $" }
        // Rounded as it will be shown, half up: 0.00005 is 0.0001, not 0.0000.
        let shown = (value * 10_000).rounded() / 10_000
        guard shown >= 0.0001 else {
            let floor = money(0.0001, decimals: 4, in: language)
            return english ? "under \(floor)" : "unter \(floor)"
        }
        return money(shown, decimals: 4, in: language)
    }

    /// What a "Ausprobieren" took and, where known, cost: "0,7 s · 0,0001 $".
    /// nil when it sent nothing. No model name: the model is shown above.
    public static func tryLine(seconds: Double?, dollars: Double?, in language: Language = .current) -> String? {
        var parts: [String] = []
        if let seconds { parts.append(seconds.formatted(.number.precision(.fractionLength(1)).locale(locale(language))) + " s") }
        if let dollars { parts.append(smallDollars(dollars, in: language)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "0,01 $ pro Stunde", "unter 0,01 $ pro Stunde", "kostenlos".
    static func perHour(_ value: Double, in language: Language) -> String {
        let english = language == .english
        if value == 0 { return english ? "free" : "kostenlos" }
        if value < 0.01 { return english ? "under \(dollars(0.01, in: language)) an hour" : "unter \(dollars(0.01, in: language)) pro Stunde" }
        return english ? "\(dollars(value, in: language)) an hour" : "\(dollars(value, in: language)) pro Stunde"
    }

    /// One menu item: "Claude Haiku 5.5 · Anthropic · +1,3 s · 0,01 $ pro Stunde".
    public static func title(_ model: CleanupModel, _ estimate: CleanupEstimate, in language: Language = .current) -> String {
        var parts = [model.name, model.maker]
        if let seconds = estimate.seconds { parts.append(Self.seconds(seconds, in: language)) }
        if model.isFree {
            parts.append(language == .english ? "free" : "kostenlos")
        } else if let hour = estimate.dollarsPerHour {
            parts.append(perHour(hour, in: language))
        }
        return parts.joined(separator: " · ")
    }

    /// The line under the model (5.3), then the model's note.
    /// - Parameter priceNote: said instead of an unknown price (Azure's
    ///   "Preis je nach Bereitstellung").
    public static func facts(_ model: CleanupModel, _ estimate: CleanupEstimate, note: String? = nil, priceNote: String? = nil,
                             in language: Language = .current) -> String {
        let english = language == .english
        let talking = max(5, (estimate.talkingSeconds / 5).rounded() * 5)
        let talkingWords = english ? "\(Int(talking)) seconds" : "\(Int(talking)) Sekunden"
        let hour = estimate.dollarsPerHour.map { value -> String in
            if value < 0.01 {
                return english ? "under \(dollars(0.01, in: language)) per hour of talking" : "unter \(dollars(0.01, in: language)) pro Stunde Sprechen"
            }
            return english ? "\(dollars(value, in: language)) per hour of talking" : "\(dollars(value, in: language)) pro Stunde Sprechen"
        }
        var sentence: String
        switch (estimate.seconds, estimate.measured, model.isFree ? nil : hour) {
        case (let seconds?, true, let hour?):
            sentence = english
                ? "\(Self.seconds(seconds, in: language)) per dictation, measured on this computer, and \(hour)."
                : "\(Self.seconds(seconds, in: language)) pro Diktat, gemessen auf diesem Computer, und \(hour)."
        case (let seconds?, false, let hour?):
            sentence = english
                ? "About \(Self.seconds(seconds, in: language)) per dictation and \(hour), for dictations of about \(talkingWords)."
                : "Etwa \(Self.seconds(seconds, in: language)) pro Diktat und \(hour), für Diktate von etwa \(talkingWords)."
        case (let seconds?, let measured, nil):
            let time = measured
                ? (english ? "\(Self.seconds(seconds, in: language)) per dictation, measured on this computer" : "\(Self.seconds(seconds, in: language)) pro Diktat, gemessen auf diesem Computer")
                : (english ? "About \(Self.seconds(seconds, in: language)) per dictation" : "Etwa \(Self.seconds(seconds, in: language)) pro Diktat")
            sentence = time + "." + (model.isFree ? "" : " " + (priceNote ?? (english ? "Price unknown." : "Preis unbekannt.")))
        case (nil, _, let hour?):
            sentence = (english ? "Time: not measured yet. " : "Zeit: noch nicht gemessen. ") + hour.prefix(1).uppercased() + hour.dropFirst() + "."
        case (nil, _, nil):
            sentence = english ? "Time: not measured yet." : "Zeit: noch nicht gemessen."
            if !model.isFree { sentence += " " + (priceNote ?? (english ? "Price unknown." : "Preis unbekannt.")) }
        }
        guard let note, !note.isEmpty else { return sentence }
        return sentence + " " + note
    }
}
