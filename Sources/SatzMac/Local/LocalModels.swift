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
    /// Replaced only by snapshots, with a stand-in in fixed states.
    static var shared = LocalModels()

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

        /// Two or three words, for the card.
        var short: String {
            switch self {
            case .notDownloaded: de("Modell fehlt", en: "Model missing")
            case .language: de("Sprache fehlt", en: "Language missing")
            }
        }
    }

    private var states: [String: State] = [:]
    /// How fast each model ran on this Mac, by id; kept in the preferences.
    private(set) var speeds: [String: LocalSpeed] = [:]
    /// Models being timed right now.
    private(set) var measuring: Set<String> = []
    /// The builds Argmax supports on this chip: WhisperKit's own copy of the
    /// list at first, then the one in Argmax's repository, asked once a run.
    private(set) var supported: Set<String> = Set(WhisperKit.recommendedModels().supported)
    @ObservationIgnored private var askedForSupport = false

    /// The Whisper model in memory. Loading it takes seconds, so it stays.
    @ObservationIgnored private var loaded: (variant: String, kit: Task<Kit, any Error>)?
    /// A model loaded beside the one in use, only to prepare and time it
    /// after its download: the one in use stays loaded meanwhile. Taken over
    /// as `loaded` if it is chosen before it is let go.
    @ObservationIgnored private var spare: (variant: String, kit: Task<Kit, any Error>)?
    /// One transcription at a time: WhisperKit is not made for two at once.
    /// Speed tests queue here too, so one never runs beside a dictation.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Speed tests, one after another, each with the load it needs: two at
    /// once slowed each other's numbers down.
    @ObservationIgnored private var tests: Task<Void, Never>?
    /// The test using each model now. A model is let go only after it:
    /// freed under a test, WhisperKit loaded it again inside the timed run,
    /// and the number came out nearly twice as slow.
    @ObservationIgnored private var inTest: [String: Task<Void, Never>] = [:]
    /// Loads under way, and how many ever started: a timed run with a load
    /// beside it shared the chip with it, so it does not count.
    @ObservationIgnored private var loadsRunning = 0
    @ObservationIgnored private var loadsStarted = 0

    /// Whether a model's files are complete on this Mac. A stand-in answers
    /// for snapshots.
    @ObservationIgnored var isOnMac: (String) -> Bool = { LocalModels.folder(of: $0) != nil }
    /// nil for a stand-in, whose speeds must not reach the preferences.
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.speedsKey),
           let kept = try? JSONDecoder().decode([String: LocalSpeed].self, from: data) {
            speeds = kept
        }
    }

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
        return isOnMac(model) ? .ready : .missing
    }

    func isReady(_ model: String, language: Language) -> Bool {
        state(of: model, language: language) == .ready
    }

    /// On this Mac, even while it loads: Setup must not call a model that is
    /// only being prepared after an update "missing".
    func isInstalled(_ model: String, language: Language) -> Bool {
        switch state(of: model, language: language) {
        case .ready: true
        case .preparing: model == ModelCatalog.apple || isOnMac(model)
        default: false
        }
    }

    /// Download, then use: a finished download becomes the model in use only
    /// when the one in use is not on this Mac. One that is being prepared
    /// is: its files are complete, it only waits for macOS. A second
    /// download finishing in those minutes took its place, and unloaded it
    /// halfway through its first load.
    func takesOver(_ downloaded: String, inUse: String, language: Language) -> Bool {
        guard downloaded != inUse else { return false }
        switch state(of: inUse, language: language) {
        case .ready, .preparing: return false
        default: return true
        }
    }

    /// Whether the model is the one in use, asked when a download ends: set
    /// by the app, so a model nobody picks is loaded only beside it.
    var isWanted: (String) -> Bool = { _ in true }
    /// A download's files are complete: the app makes it the model in use
    /// when `takesOver` says so, so Lokal works at once.
    @ObservationIgnored var onDownloaded: (String) -> Void = { _ in }
    /// The word list as dictations send it, for timing a model the same way.
    @ObservationIgnored var vocabulary: () -> [String] = { [] }
    /// True while someone dictates: a speed test waits for it to end.
    @ObservationIgnored var isDictating: () -> Bool = { false }

    /// Only one download at a time: two at once halve each other's speed.
    var isDownloading: Bool {
        states.values.contains { if case .downloading = $0 { true } else { false } }
    }

    /// Asks macOS whether Apple's model for the spoken language is installed.
    func check(_ model: String, language: Language) async {
        guard model == ModelCatalog.apple, #available(macOS 26, *) else { return }
        let key = Self.appleKey(language)
        if case .downloading = states[key] { return }
        let status = await Self.appleStatus(language)
        guard !isBusy(key) else { return }
        // A download macOS runs for someone else would sit at 0 % here
        // forever: offered as Download instead, which joins it.
        if case .downloading = status { states[key] = .missing } else { states[key] = status }
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
            let folder: URL
            do {
                folder = try await WhisperKit.download(variant: model, downloadBase: Self.base) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in self.progress(model, fraction) }
                }
            } catch {
                failed(model, error)
                return
            }
            onDownloaded(model)
            // Loaded once now, so the first dictation does not wait while
            // macOS builds the model for this chip, and so the tokenizer,
            // fetched at the first load, is there before the model counts
            // as on this Mac (an offline first load failed otherwise).
            // Then timed while it is in memory anyway: both after any test
            // already running, and without letting the model go in between.
            states[model] = .preparing
            await inLane(model) {
                let started = Date()
                let kit: Task<Kit, any Error>
                // A model not in use is loaded beside the one that is.
                if self.isWanted(model) {
                    if self.loaded?.variant == model { self.unload() }
                    kit = self.kit(model, folder: folder)
                } else {
                    kit = self.loadSpare(model, folder: folder)
                }
                do {
                    _ = try await kit.value
                    try folder.path.write(to: Self.marker(model), atomically: true, encoding: .utf8)
                } catch {
                    self.failed(model, error)
                    self.releaseSpare(model)
                    return
                }
                Self.prepared.insert(Self.preparedKey(model))
                Log.note(String(format: "local: %@ ready after %.0f s", model, Date().timeIntervalSince(started)))
                self.states[model] = .ready
                await self.time(model, language: language, kit: kit)
            }
        }
    }

    private func failed(_ model: String, _ error: any Error) {
        Log.note("local: \(model) failed: \(error.localizedDescription)")
        states[model] = .failed(error.localizedDescription)
    }

    /// Into the Trash, like everything satz removes.
    func remove(_ model: String) {
        guard model != ModelCatalog.apple, let folder = Self.folder(of: model) else { return }
        if loaded?.variant == model { unload() }
        releaseSpare(model)
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
                onDownloaded(ModelCatalog.apple)
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
        default: measuring.contains(key)
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
        free(loaded.kit, of: loaded.variant, note: "local: \(loaded.variant) unloaded")
    }

    /// Frees a model once nothing needs it any more: not the transcriptions
    /// queued now (freed under one, it failed with "Fehler"), and not a speed
    /// test using it.
    private func free(_ kit: Task<Kit, any Error>, of variant: String, note: String) {
        let pending = queue, test = inTest[variant]
        Task.detached {
            _ = await pending?.value
            _ = await test?.value
            if let kit = try? await kit.value { await kit.whisper.unloadModels() }
            Log.note(note)
        }
    }

    /// Every load goes through here, so a speed test knows when one runs.
    private func startLoad(_ variant: String, folder: URL?) -> Task<Kit, any Error> {
        loadsStarted += 1
        loadsRunning += 1
        return Task {
            defer { loadsRunning -= 1 }
            return try await Self.load(variant, folder: folder)
        }
    }

    private func kit(_ variant: String, folder: URL? = nil) -> Task<Kit, any Error> {
        if let loaded, loaded.variant == variant { return loaded.kit }
        unload()
        // Chosen while it was loaded for its speed test: kept, not loaded twice.
        if let spare, spare.variant == variant {
            self.spare = nil
            loaded = spare
            return spare.kit
        }
        let task = startLoad(variant, folder: folder)
        loaded = (variant, task)
        let started = Date()
        // macOS builds the model for this chip once per app and version:
        // minutes, during which a dictation would seem to hang. Said instead.
        // Only cleared here if set here: a download sets and clears its own.
        let saysPreparing = !Self.prepared.contains(Self.preparedKey(variant)) && states[variant] == nil
        if saysPreparing { states[variant] = .preparing }
        Task {
            switch await task.result {
            case .success:
                Log.note(String(format: "local: %@ loaded in %.1f s", variant, Date().timeIntervalSince(started)))
                Self.prepared.insert(Self.preparedKey(variant))
            case .failure(let error):
                // A failed load is tried again by the next dictation.
                Log.note("local: loading \(variant) failed: \(error.localizedDescription)")
                if loaded?.kit == task { loaded = nil }
            }
            if saysPreparing, states[variant] == .preparing { states[variant] = nil }
        }
        return task
    }

    /// Loads a model beside the one in use. Only from the test lane, so there
    /// is never more than one.
    private func loadSpare(_ variant: String, folder: URL? = nil) -> Task<Kit, any Error> {
        if let loaded, loaded.variant == variant { return loaded.kit }
        if let spare, spare.variant == variant { return spare.kit }
        releaseSpare()
        let task = startLoad(variant, folder: folder)
        spare = (variant, task)
        return task
    }

    /// Lets the spare go once nothing needs it; only `variant`'s, if given.
    private func releaseSpare(_ variant: String? = nil) {
        guard let spare, variant == nil || spare.variant == variant else { return }
        self.spare = nil
        free(spare.kit, of: spare.variant, note: "local: \(spare.variant) let go after its speed test")
    }

    /// What is in memory, for the test mode's state file.
    var inMemory: (loaded: String?, spare: String?) { (loaded?.variant, spare?.variant) }

    /// Models this app, in this version and on this macOS build, has loaded
    /// before: CoreML's compiled copy goes with a macOS update too.
    private static var prepared: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "localPrepared") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "localPrepared") }
    }

    private static func preparedKey(_ variant: String) -> String {
        "\(variant)@\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")@\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    // MARK: - Transcribing

    /// - Parameter samples: 16 kHz mono, as recorded.
    func transcribe(_ samples: [Float], model: String, language: Language, vocabulary: [String]) async throws -> String {
        if model == ModelCatalog.apple {
            guard #available(macOS 26, *) else { throw Failure.language }
            return try await queued { try await Self.appleTranscribe(samples, language: language, vocabulary: vocabulary) }
        }
        guard isReady(model, language: language) || loaded?.variant == model else { throw Failure.notDownloaded }
        let kit = kit(model)
        let englishOnly = LocalCatalog.model(model)?.isEnglishOnly ?? false
        return try await queued {
            try await Self.whisperTranscribe(samples, kit: try await kit.value, vocabulary: vocabulary, spoken: language, englishOnly: englishOnly)
        }
    }

    /// Runs `work` after everything queued before it.
    private func queued<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = queue
        let job = Task {
            _ = await previous?.value
            return try await work()
        }
        queue = Task { _ = await job.result }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    // MARK: - Speed

    /// Times a model on this Mac, for its row in the list. Only on request
    /// and right after a download: never in the background on its own.
    func measure(_ model: String, language: Language) {
        guard model != ModelCatalog.apple, isOnMac(model), !isBusy(model) else { return }
        // Shown as being timed while it waits for a test before it.
        measuring.insert(model)
        Task { await inLane(model) { await self.time(model, language: language, kit: nil) } }
    }

    /// Runs `work` for `model` once the tests before it are done, and keeps
    /// the model from being let go until `work` ends.
    private func inLane(_ model: String, _ work: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = tests
        let lane = Task {
            _ = await previous?.value
            let test = Task { await work() }
            inTest[model] = test
            await test.value
            if inTest[model] == test { inTest[model] = nil }
        }
        tests = lane
        await lane.value
    }

    /// satz's 10 s clip, through the transcription a dictation uses, with the
    /// word list as it is (so a second pass with it counts too), in the
    /// dictations' queue. Twice: the first run warms the model up, the
    /// second is what a dictation feels. A model not in use is loaded for
    /// this only, and let go after. Only from the test lane.
    private func time(_ model: String, language: Language, kit given: Task<Kit, any Error>?) async {
        measuring.insert(model)
        defer {
            measuring.remove(model)
            releaseSpare(model)
        }
        do {
            guard let clip = Self.speedClip else { throw Failure.notDownloaded }
            let kit = given ?? (loaded?.variant == model || isWanted(model) ? self.kit(model) : loadSpare(model))
            let whisper = try await kit.value
            let vocabulary = vocabulary()
            var elapsed: TimeInterval?
            var runs = 0
            // A run with another model loading beside it is run again: the
            // load took the chip too, which no dictation has to share.
            while elapsed == nil, runs < 5 {
                // Never while someone is talking (their text would wait for
                // it), nor while a model loads.
                while isDictating() || loadsRunning > 0 { try await Task.sleep(for: .milliseconds(500)) }
                let loadsBefore = loadsStarted
                let took = try await queued {
                    let started = Date()
                    _ = try await Self.whisperTranscribe(clip, kit: whisper, vocabulary: vocabulary, spoken: language,
                                                         englishOnly: LocalCatalog.model(model)?.isEnglishOnly ?? false)
                    return Date().timeIntervalSince(started)
                }
                runs += 1
                if runs >= 2, loadsStarted == loadsBefore { elapsed = took }
            }
            guard let elapsed else {
                Log.note("local: timing \(model) gave up, other models kept loading beside it")
                return
            }
            let seconds = LocalSpeed.secondsPer10(elapsed: elapsed, clipSeconds: Double(clip.count) / 16_000)
            speeds[model] = LocalSpeed(secondsPer10: seconds, measured: Date(), version: Self.version, machine: Chip.current ?? "?")
            if let data = try? JSONEncoder().encode(speeds) { defaults?.set(data, forKey: Self.speedsKey) }
            Log.note(String(format: "local: %@ takes %.1f s per 10 s of speech", model, seconds))
        } catch {
            Log.note("local: timing \(model) failed: \(error.localizedDescription)")
        }
    }

    private static let speedsKey = "localSpeeds"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The clip the speed is measured with (Resources/speedtest.wav, see
    /// speedtest.txt): 10 s of a public-domain reading, 16 kHz mono.
    nonisolated static let speedClip: [Float]? = {
        guard let url = Bundle.main.url(forResource: "speedtest", withExtension: "wav"),
              let data = try? Data(contentsOf: url), let clip = WAVDecoder.decode(data), clip.sampleRate == 16_000
        else { return nil }
        return clip.samples
    }()

    /// Which builds this chip runs, from Argmax's repository: once a run, in
    /// the background, falling back to WhisperKit's copy when it cannot.
    func refreshSupport() {
        guard !askedForSupport else { return }
        askedForSupport = true
        Task {
            let support = await WhisperKit.recommendedRemoteModels(downloadBase: Self.base)
            if !support.supported.isEmpty { supported = Set(support.supported) }
            let offered = LocalCatalog.offered(supported: supported, hasApple: false).map(\.id)
            Log.note("local: \(support.supported.count) builds supported on \(WhisperKit.deviceName()), offered: \(offered.joined(separator: ", "))")
        }
    }

    /// Fixed states, for snapshots.
    func stage(states: [String: State], speeds: [String: LocalSpeed], supported: Set<String>, onMac: Set<String>, measuring: Set<String> = []) {
        self.states = states
        self.speeds = speeds
        self.supported = supported
        self.measuring = measuring
        askedForSupport = true
        isOnMac = { onMac.contains($0) }
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

    nonisolated private static func load(_ variant: String, folder given: URL?) async throws -> Kit {
        guard let folder = given ?? folder(of: variant) else { throw Failure.notDownloaded }
        let config = WhisperKitConfig(model: variant, downloadBase: base, modelFolder: folder.path,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        return Kit(try await WhisperKit(config))
    }

    nonisolated private static func whisperTranscribe(_ samples: [Float], kit: Kit, vocabulary: [String], spoken: Language,
                                                      englishOnly: Bool = false) async throws -> String {
        // Whisper makes something up for silence ("Vielen Dank.").
        guard SpeechGate.hasSpeech(samples) else { return "" }
        let decode = { (prompt: [Int]?, limit: Int?) async throws -> String in
            // Whisper finds the language itself, per recording, so German and
            // English both work without a setting. With timestamps, a
            // recording over 30 s goes on where a sentence ended instead of
            // being cut at 30 s; and a clip under a second is decoded too
            // (windowClipTime 1 skipped it).
            var options = DecodingOptions(task: .transcribe, language: nil, temperature: 0, usePrefillPrompt: true,
                                          detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: false,
                                          windowClipTime: 0)
            // Under two seconds the language guess is a coin toss ("Ja." came
            // back as "Yeah." on Windows/Linux): the one set in Settings. A
            // model that hears English only is never asked.
            if englishOnly {
                options.language = Language.english.rawValue
                options.detectLanguage = false
            } else if samples.count < 32_000 {
                options.language = spoken.rawValue
                options.detectLanguage = false
            }
            options.promptTokens = prompt
            if let limit { options.sampleLength = limit }
            // A poor prompted reading is thrown away anyway (keepEveryWord):
            // WhisperKit's retries at higher temperatures only cost time,
            // up to five more decodes (Small took 2.8 s instead of 1.0).
            if prompt != nil { options.temperatureFallbackCount = 0 }
            let results = try await kit.whisper.transcribe(audioArray: samples, decodeOptions: options)
            return results.map(\.text).joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let plain = try await decode(nil, nil)
        guard !vocabulary.isEmpty, !plain.isEmpty, let tokenizer = kit.whisper.tokenizer else { return plain }
        // The word list goes in as Whisper's own prompt: text it takes as
        // having come before, so it spells those words the same way. It
        // copies the prompt's style too: without the full stop, sentences
        // came back without theirs.
        let prompt = tokenizer.encode(text: " " + vocabulary.joined(separator: ", ") + ".")
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // Prompted with German trigger words, English speech sometimes came
        // back as "Klammer zu Klammer zu …" until the token limit, seconds
        // spent on text that is thrown away. Twice the plain text's length
        // (plus room for timestamps) is more than any honest reading needs;
        // one cut short loses words, so the plain text is kept.
        let limit = 2 * tokenizer.encode(text: plain).count + 20
        let kept = WordCheck.keepEveryWord(prompted: try await decode(prompt, limit), plain: plain)
        if !kept.usedPrompt { Log.note("local: the word list cost words here, kept the text without it") }
        return kept.text
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
