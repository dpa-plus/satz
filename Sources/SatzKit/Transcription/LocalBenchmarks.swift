import Foundation

/// What Argmax, who make WhisperKit, measured for the exact builds satz
/// downloads: word errors in English and German, and how fast each ran on
/// each Apple chip. Read from their public dashboard, kept for a day, and
/// shipped with satz for when it cannot be reached. Only for the Mac:
/// nobody publishes numbers for Apple's own recognizer.
public struct LocalBenchmarks: Codable, Hashable, Sendable {
    /// Word errors in percent on English speech (LibriSpeech and
    /// Earnings-22), by model id.
    public var english: [String: Double]
    /// Word errors in percent on German speech (Common Voice 17) with the
    /// language found by Whisper itself, as satz runs it. Missing for a build
    /// Argmax did not test in German: no other build's number stands in.
    public var german: [String: Double]
    /// Seconds of speech done per second of work on LibriSpeech's short
    /// clips, by model id, then by chip as Argmax names it ("Apple M4 Pro").
    public var speed: [String: [String: Double]]

    public init(english: [String: Double], german: [String: Double], speed: [String: [String: Double]]) {
        self.english = english
        self.german = german
        self.speed = speed
    }

    /// From the live files on 08.10.2026 (dashboard data last changed
    /// 17.10.2025). English is quality_data.json's average_wer, the one
    /// figure Argmax gives every build on the same speech: v20240930_turbo
    /// 6.72 and 626MB 7.15 there, where performance_data.json's runs on one
    /// M4 Pro say 6.14 and 6.42. German is multilingual_results.csv, WER_de
    /// with "Forced Tokens" False. Speed is each chip's latest run in
    /// performance_data.json, librispeech-10mins (M4 Pro: turbo_632MB
    /// 11.49, turbo 11.78, 626MB 7.32, small 21.08).
    public static let bundled = LocalBenchmarks(
        english: [
            LocalCatalog.turbo: 6.86,
            LocalCatalog.turboFull: 6.72,
            LocalCatalog.turboCompatible: 7.15,
            LocalCatalog.largeV3: 6.85,
            LocalCatalog.distil: 8.33,
            LocalCatalog.distilCompatible: 8.96,
            LocalCatalog.small: 8.11,
            LocalCatalog.base: 10.67,
            LocalCatalog.tiny: 14.21,
        ],
        german: [
            LocalCatalog.turboCompatible: 14.69,
            LocalCatalog.largeV3: 14.75,
            LocalCatalog.small: 49.17,
            LocalCatalog.base: 61.29,
            LocalCatalog.tiny: 79.95,
        ],
        speed: [
            // Added 09.10.2026 from the same files, same rules.
            LocalCatalog.largeV3: [
                "Apple M2": 2.25, "Apple M2 Pro": 2.38, "Apple M2 Ultra": 2.26, "Apple M3 Pro": 2.46, "Apple M3 Max": 2.3, "Apple M4": 2.7, "Apple M4 Pro": 3.18,
            ],
            LocalCatalog.distil: [
                "Apple M2": 10.62, "Apple M2 Pro": 10.75, "Apple M2 Ultra": 10.59, "Apple M3 Pro": 11.27, "Apple M3 Max": 11.62, "Apple M4": 12.87, "Apple M4 Pro": 14.32,
            ],
            LocalCatalog.distilCompatible: [
                "Apple M1": 5.29, "Apple M2": 6.53, "Apple M2 Pro": 6.67, "Apple M2 Ultra": 6.67, "Apple M3 Pro": 7.14, "Apple M3 Max": 6.99, "Apple M4": 7.61, "Apple M4 Pro": 8.38,
            ],
            LocalCatalog.base: [
                "Apple M1": 32.17, "Apple M2": 40.0, "Apple M2 Pro": 37.25, "Apple M2 Ultra": 30.48, "Apple M3 Pro": 36.37, "Apple M3 Max": 33.91, "Apple M4": 48.28, "Apple M4 Pro": 50.3,
            ],
            LocalCatalog.tiny: [
                "Apple M1": 45.02, "Apple M2": 53.91, "Apple M2 Pro": 49.67, "Apple M2 Ultra": 39.99, "Apple M3 Pro": 49.26, "Apple M3 Max": 46.65, "Apple M4": 71.19, "Apple M4 Pro": 68.28,
            ],
            LocalCatalog.turbo: [
                "Apple M2": 8.54, "Apple M2 Pro": 8.83, "Apple M2 Ultra": 8.52, "Apple M3 Pro": 6.55,
                "Apple M3 Max": 9.46, "Apple M4": 10.53, "Apple M4 Pro": 11.49,
            ],
            LocalCatalog.turboFull: [
                "Apple M2": 8.88, "Apple M2 Pro": 8.79, "Apple M2 Ultra": 8.58, "Apple M3 Pro": 7.0,
                "Apple M3 Max": 9.55, "Apple M4": 10.66, "Apple M4 Pro": 11.78,
            ],
            LocalCatalog.turboCompatible: [
                "Apple M1": 4.65, "Apple M2": 5.69, "Apple M2 Pro": 5.83, "Apple M2 Ultra": 5.78, "Apple M3 Pro": 4.55,
                "Apple M3 Max": 5.99, "Apple M4": 6.74, "Apple M4 Pro": 7.32,
            ],
            LocalCatalog.small: [
                "Apple M1": 11.78, "Apple M2": 14.3, "Apple M2 Pro": 14.53, "Apple M2 Ultra": 12.86, "Apple M3 Pro": 15.54,
                "Apple M3 Max": 14.69, "Apple M4": 18.32, "Apple M4 Pro": 21.08,
            ],
        ]
    )

    /// How long 10 s of speech should take on this chip, from the nearest
    /// chip Argmax measured, and which one that was.
    public func estimate(_ id: String, chip: String?) -> (secondsPer10: Double, chip: String)? {
        guard let chip = chip.flatMap(Chip.init), let speeds = speed[id],
              let nearest = chip.nearest(in: speeds.keys), let speed = speeds[nearest], speed > 0 else { return nil }
        return (10 / speed, nearest)
    }

    /// The estimate, scaled by how this Mac did on a model it has measured
    /// (the most recent one): Argmax times one plain decode, satz also runs
    /// the word list's pass, and the chip is often not the one Argmax had.
    /// Unscaled, Small read "ca. 0,5 s" and took 1,0 s. `scaledBy` names the
    /// measured model, nil when nothing on this chip has been measured.
    public func estimate(_ id: String, chip: String?, measured: [String: LocalSpeed])
        -> (secondsPer10: Double, chip: String, scaledBy: String?)? {
        guard let plain = estimate(id, chip: chip) else { return nil }
        let reference = measured
            .filter { $0.key != id && $0.value.machine == (chip ?? $0.value.machine) }
            .compactMap { key, speed in estimate(key, chip: chip).map { (key: key, speed: speed, argmax: $0.secondsPer10) } }
            .max { $0.speed.measured < $1.speed.measured }
        guard let reference, reference.argmax > 0 else { return (plain.secondsPer10, plain.chip, nil) }
        return (plain.secondsPer10 * reference.speed.secondsPer10 / reference.argmax, plain.chip, reference.key)
    }

    // MARK: - Live

    static let dashboard = URL(string: "https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks/resolve/main/dashboard_data/")!

    /// The three files, each read by its field and column names. A file that
    /// cannot be read or holds none of satz's models keeps the shipped
    /// numbers for its part; only when all three fail does this throw.
    public static func fetch(ids: [String] = LocalCatalog.whisperIDs, session: URLSession = .shared) async throws -> LocalBenchmarks {
        async let quality = download("quality_data.json", session: session)
        async let languages = download("multilingual_results.csv", session: session)
        async let performance = download("performance_data.json", session: session)
        let english = (await quality).map { parseEnglish($0, ids: ids) } ?? [:]
        let german = (await languages).map { parseGerman($0, ids: ids) } ?? [:]
        let speed = (await performance).map { parseSpeed($0, ids: ids) } ?? [:]
        guard !english.isEmpty || !german.isEmpty || !speed.isEmpty else { throw URLError(.cannotParseResponse) }
        return LocalBenchmarks(english: english.isEmpty ? bundled.english : english,
                               german: german.isEmpty ? bundled.german : german,
                               speed: speed.isEmpty ? bundled.speed : speed)
    }

    private static func download(_ file: String, session: URLSession) async -> Data? {
        let request = URLRequest(url: dashboard.appendingPathComponent(file), timeoutInterval: 20)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// The dashboard writes a model's id with "/" for "_":
    /// openai_whisper-large-v3-v20240930_turbo_632MB is
    /// openai/whisper-large-v3-v20240930/turbo/632MB there.
    static func dashboardName(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: "/")
    }

    /// quality_data.json: one JSON object per line, `model` and `average_wer`.
    static func parseEnglish(_ data: Data, ids: [String]) -> [String: Double] {
        let wanted = Dictionary(uniqueKeysWithValues: ids.map { (dashboardName($0), $0) })
        var result: [String: Double] = [:]
        for row in jsonRows(data) {
            guard let model = row["model"] as? String, let id = wanted[model],
                  let wer = number(row["average_wer"]) else { continue }
            result[id] = wer
        }
        return result
    }

    /// multilingual_results.csv: `Model`, `Forced Tokens` and `WER_de`. The
    /// row where the language was not forced, because satz does not force it.
    static func parseGerman(_ data: Data, ids: [String]) -> [String: Double] {
        let wanted = Dictionary(uniqueKeysWithValues: ids.map { (dashboardName($0), $0) })
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(csvFields)
        guard let header = lines.first,
              let model = header.firstIndex(of: "Model"), let forced = header.firstIndex(of: "Forced Tokens"),
              let german = header.firstIndex(of: "WER_de") else { return [:] }
        var result: [String: Double] = [:]
        for fields in lines.dropFirst() where fields.count == header.count {
            guard let id = wanted[fields[model]], fields[forced].lowercased() == "false",
                  let wer = Double(fields[german]) else { continue }
            result[id] = wer
        }
        return result
    }

    /// performance_data.json: one run per line, `model`, `device`,
    /// `timestamp` and `dataset_speed["librispeech-10mins"]`. The latest run
    /// per chip. LibriSpeech's clips are dictation-length; the overall
    /// `speed` cuts long audio into 16 pieces at once, which satz never does.
    static func parseSpeed(_ data: Data, ids: [String]) -> [String: [String: Double]] {
        let wanted = Dictionary(uniqueKeysWithValues: ids.map { (dashboardName($0), $0) })
        var latest: [String: [String: (time: String, speed: Double)]] = [:]
        for row in jsonRows(data) {
            guard let model = row["model"] as? String, let id = wanted[model],
                  let device = row["device"] as? String, Chip(device) != nil,
                  let speed = number((row["dataset_speed"] as? [String: Any])?["librispeech-10mins"]), speed > 0 else { continue }
            let time = row["timestamp"] as? String ?? ""
            if let kept = latest[id]?[device], kept.time >= time { continue }
            latest[id, default: [:]][device] = (time, speed)
        }
        return latest.mapValues { $0.mapValues(\.speed) }
    }

    /// One JSON object per line; a JSON array is taken too, should the
    /// dashboard ever write one.
    private static func jsonRows(_ data: Data) -> [[String: Any]] {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return array }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    /// Fields of one CSV line; a quoted field may hold commas.
    static func csvFields<S: StringProtocol>(_ line: S) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        for character in line {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted:
                fields.append(field)
                field = ""
            default: field.append(character)
            }
        }
        fields.append(field)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// An Apple chip by generation and tier, to find the nearest one Argmax
/// measured: this Mac's own, else the same tier one generation older, and
/// so on down, then the next smaller tier. Never a newer chip.
public struct Chip: Hashable, Sendable {
    public enum Tier: Int, Sendable { case plain, pro, max, ultra }

    public let generation: Int
    public let tier: Tier

    /// "Apple M4 Pro", as macOS (`machdep.cpu.brand_string`) and Argmax
    /// write it. nil for an Intel Mac or a phone.
    public init?(_ name: String) {
        let words = name.split(separator: " ")
        guard words.count >= 2, words[0] == "Apple", words[1].first == "M",
              let generation = Int(words[1].dropFirst()) else { return nil }
        self.generation = generation
        switch words.count > 2 ? String(words[2]) : "" {
        case "": tier = .plain
        case "Pro": tier = .pro
        case "Max": tier = .max
        case "Ultra": tier = .ultra
        default: return nil
        }
    }

    init(generation: Int, tier: Tier) {
        self.generation = generation
        self.tier = tier
    }

    public var name: String {
        switch tier {
        case .plain: "Apple M\(generation)"
        case .pro: "Apple M\(generation) Pro"
        case .max: "Apple M\(generation) Max"
        case .ultra: "Apple M\(generation) Ultra"
        }
    }

    /// The closest of `names` to this chip, nil if none is this one or older.
    public func nearest(in names: some Sequence<String>) -> String? {
        let measured = Set(names.compactMap(Chip.init))
        for tier in (0 ... tier.rawValue).reversed().compactMap(Tier.init(rawValue:)) {
            for generation in stride(from: generation, through: 1, by: -1) {
                let candidate = Chip(generation: generation, tier: tier)
                if measured.contains(candidate) { return candidate.name }
            }
        }
        return nil
    }

    /// This Mac's chip as macOS names it ("Apple M5 Pro"); nil if unreadable.
    public static var current: String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        let name = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
