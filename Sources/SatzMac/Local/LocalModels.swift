import AVFoundation
import Foundation
import Observation
import SatzKit
import Speech
import WhisperKit

/// Speech recognition on this Mac, for the provider "Lokal": Whisper through
/// WhisperKit, downloaded once, and Apple's own, built into macOS 26. Nothing
/// leaves the Mac and nothing costs anything; the price is a download, and
/// the memory a loaded model takes.
@MainActor
@Observable
final class LocalModels {

    /// One per app: a loaded model is large, and there is one microphone.
    static let shared = LocalModels()

    enum State: Equatable {
        /// Needs a download first.
        case missing
        case downloading(Double)
        /// The first load after a download, while macOS builds the model for
        /// this Mac's chip: a minute or more, once.
        case preparing
        case ready
        /// Cannot run on this Mac, and why.
        case unavailable(String)
        case failed(String)
    }

    enum Failure: Error, LocalizedError {
        case notDownloaded
        case language

        var errorDescription: String? {
            switch self {
            case .notDownloaded: de("Das Modell ist noch nicht geladen.", en: "The model has not been downloaded yet.")
            case .language: de("Apples Spracherkennung kennt diese Sprache nicht.", en: "Apple's speech recognition does not know this language.")
            }
        }
    }

    private var states: [String: State] = [:]

    /// The Whisper model in memory. Loading it takes seconds, so it stays.
    @ObservationIgnored private var loaded: (variant: String, kit: Task<Kit, any Error>)?
    /// One transcription at a time: WhisperKit is not made for two at once.
    @ObservationIgnored private var queue: Task<Void, Never>?

    /// Where WhisperKit keeps models and tokenizers.
    nonisolated static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("satz/models/whisperkit", isDirectory: true)

    /// WhisperKit is a class without Sendable; satz only ever uses one from
    /// one transcription at a time (`queue`).
    final class Kit: @unchecked Sendable {
        let whisper: WhisperKit
        init(_ whisper: WhisperKit) { self.whisper = whisper }
    }

    // MARK: - State

    func state(of model: String, language: Language) -> State {
        if model == ModelCatalog.apple {
            guard #available(macOS 26, *) else { return .unavailable(de("Braucht macOS 26.", en: "Needs macOS 26.")) }
            // Taken as there until `check` has asked macOS.
            return states[Self.appleKey(language)] ?? .ready
        }
        if let state = states[model] { return state }
        return Self.folder(of: model) != nil ? .ready : .missing
    }

    func isReady(_ model: String, language: Language) -> Bool {
        state(of: model, language: language) == .ready
    }

    /// Asks macOS whether Apple's model for the spoken language is installed.
    func check(_ model: String, language: Language) async {
        guard model == ModelCatalog.apple, #available(macOS 26, *) else { return }
        let key = Self.appleKey(language)
        if case .downloading = states[key] { return }
        let status = await Self.appleStatus(language)
        guard !isBusy(key) else { return }
        states[key] = status
    }

    // MARK: - Download

    func download(_ model: String, language: Language) {
        if model == ModelCatalog.apple {
            downloadApple(language)
            return
        }
        guard !isBusy(model) else { return }
        states[model] = .downloading(0)
        Log.note("local: downloading \(model)")
        Task {
            do {
                let folder = try await WhisperKit.download(variant: model, downloadBase: Self.base) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in self.progress(model, fraction) }
                }
                try folder.path.write(to: Self.marker(model), atomically: true, encoding: .utf8)
                // Loaded once now, so the first dictation does not wait while
                // macOS builds the model for this chip.
                states[model] = .preparing
                if loaded?.variant == model { unload() }
                let started = Date()
                _ = try await kit(model).value
                Log.note(String(format: "local: %@ ready after %.0f s", model, Date().timeIntervalSince(started)))
                states[model] = .ready
            } catch {
                Log.note("local: \(model) failed: \(error.localizedDescription)")
                states[model] = .failed(error.localizedDescription)
            }
        }
    }

    /// Into the Trash, like everything satz removes.
    func remove(_ model: String) {
        guard model != ModelCatalog.apple, let folder = Self.folder(of: model) else { return }
        if loaded?.variant == model { unload() }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: Self.marker(model))
        states[model] = .missing
        Log.note("local: \(model) moved to the Trash")
    }

    private func downloadApple(_ language: Language) {
        guard #available(macOS 26, *) else { return }
        let key = Self.appleKey(language)
        guard !isBusy(key) else { return }
        states[key] = .downloading(0)
        Task {
            do {
                try await Self.appleInstall(language) { fraction in
                    Task { @MainActor in self.progress(key, fraction) }
                }
                states[key] = .ready
            } catch {
                states[key] = .failed(error.localizedDescription)
            }
        }
    }

    private func progress(_ key: String, _ fraction: Double) {
        if case .downloading = states[key] { states[key] = .downloading(fraction) }
    }

    private func isBusy(_ key: String) -> Bool {
        switch states[key] {
        case .downloading, .preparing: true
        default: false
        }
    }

    // MARK: - In memory

    /// Starts loading Whisper, so it is there by the time the speaking is
    /// done: seconds, which a dictation would otherwise wait for.
    func warmUp(_ model: String, language: Language) {
        guard model != ModelCatalog.apple, isReady(model, language: language) else { return }
        _ = kit(model)
    }

    /// Gives back the memory, when another provider is chosen.
    func unload() {
        guard let loaded else { return }
        self.loaded = nil
        let task = loaded.kit
        Task.detached {
            if let kit = try? await task.value { await kit.whisper.unloadModels() }
        }
    }

    private func kit(_ variant: String) -> Task<Kit, any Error> {
        if let loaded, loaded.variant == variant { return loaded.kit }
        unload()
        let task = Task<Kit, any Error> { try await Self.load(variant) }
        loaded = (variant, task)
        let started = Date()
        Task {
            switch await task.result {
            case .success:
                Log.note(String(format: "local: %@ loaded in %.1f s", variant, Date().timeIntervalSince(started)))
            case .failure(let error):
                // A failed load is tried again by the next dictation.
                Log.note("local: loading \(variant) failed: \(error.localizedDescription)")
                if loaded?.kit == task { loaded = nil }
            }
        }
        return task
    }

    // MARK: - Transcribing

    /// - Parameter samples: 16 kHz mono, as recorded.
    func transcribe(_ samples: [Float], model: String, language: Language, vocabulary: [String]) async throws -> String {
        let previous = queue
        let job: Task<String, any Error>
        if model == ModelCatalog.apple {
            guard #available(macOS 26, *) else { throw Failure.language }
            job = Task {
                _ = await previous?.value
                return try await Self.appleTranscribe(samples, language: language, vocabulary: vocabulary)
            }
        } else {
            guard isReady(model, language: language) || loaded?.variant == model else { throw Failure.notDownloaded }
            let kit = kit(model)
            job = Task {
                _ = await previous?.value
                return try await Self.whisperTranscribe(samples, kit: try await kit.value, vocabulary: vocabulary)
            }
        }
        queue = Task { _ = await job.result }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    // MARK: - Whisper

    /// The folder a finished download landed in; nil if there is none.
    nonisolated static func folder(of variant: String) -> URL? {
        guard let path = try? String(contentsOf: marker(variant), encoding: .utf8),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Written only once a download is complete: an interrupted one leaves
    /// files that look like a model and are not.
    nonisolated private static func marker(_ variant: String) -> URL {
        base.appendingPathComponent("\(variant).ready")
    }

    nonisolated private static func load(_ variant: String) async throws -> Kit {
        guard let folder = folder(of: variant) else { throw Failure.notDownloaded }
        let config = WhisperKitConfig(model: variant, downloadBase: base, modelFolder: folder.path,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        return Kit(try await WhisperKit(config))
    }

    nonisolated private static func whisperTranscribe(_ samples: [Float], kit: Kit, vocabulary: [String]) async throws -> String {
        // Whisper finds the language itself, per recording, so German and
        // English both work without a setting.
        var options = DecodingOptions(task: .transcribe, language: nil, temperature: 0, usePrefillPrompt: true,
                                      detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: true)
        // The word list goes in as Whisper's own prompt: text it takes as
        // having come before, so it spells those words the same way. It
        // copies the prompt's style too: without the full stop, sentences
        // came back without theirs.
        if !vocabulary.isEmpty, let tokenizer = kit.whisper.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", ") + ".")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Apple

    private static func appleKey(_ language: Language) -> String { "\(ModelCatalog.apple)-\(language.rawValue)" }

    /// Apple's model listens for one language, the one satz is spoken to in.
    @available(macOS 26, *)
    nonisolated private static func appleTranscriber(_ language: Language) async -> SpeechTranscriber? {
        let wanted = Locale(identifier: language == .german ? "de-DE" : "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { return nil }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    @available(macOS 26, *)
    nonisolated private static func appleStatus(_ language: Language) async -> State {
        guard let transcriber = await appleTranscriber(language) else {
            return .unavailable(Failure.language.localizedDescription)
        }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .downloading: return .downloading(0)
        case .supported: return .missing
        default: return .unavailable(Failure.language.localizedDescription)
        }
    }

    @available(macOS 26, *)
    nonisolated private static func appleInstall(_ language: Language, progress report: @escaping @Sendable (Double) -> Void) async throws {
        guard let transcriber = await appleTranscriber(language) else { throw Failure.language }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let progress = request.progress
        let watcher = Task {
            while !Task.isCancelled {
                report(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
    }

    @available(macOS 26, *)
    nonisolated private static func appleTranscribe(_ samples: [Float], language: Language, vocabulary: [String]) async throws -> String {
        guard let transcriber = await appleTranscriber(language) else { throw Failure.language }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        // A file is the one input that needs no format matching; it is
        // gone again as soon as the text is there.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("satz-\(UUID().uuidString).wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 16_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        async let text = transcriber.results.reduce(into: "") { $0 += String($1.text.characters) }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
