import AVFoundation
import Foundation

/// Captures the microphone into 16 kHz mono samples and reports a loudness
/// level while it does, so the interface can draw a waveform.
///
/// Three behaviours here are deliberate rather than incidental:
///
/// - `finishSamples()` keeps the microphone open for `Settings.tail` after it
///   is called. Stopping the instant the key is released clips the last word,
///   which is the most common complaint about dictation tools.
/// - `cancel()` throws the audio away without ever producing a file, so a
///   cancelled recording cannot be uploaded by a later mistake.
/// - A microphone that stops on its own and cannot be started again is said
///   (`onInputLost`), with everything it heard until then kept. It once went
///   quiet without a word, the card kept "listening", and every word after
///   it was lost.
public final class AudioRecorder: @unchecked Sendable {

    public struct StartupTiming: Sendable {
        public enum Stage: String, Sendable { case engineStarted, firstBuffer }
        public let stage: Stage
        /// Since opening the engine began, excluding permission and device lookup.
        public let elapsed: Duration
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case microphoneDenied
        case couldNotConvertAudio
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                de("satz braucht Zugriff auf das Mikrofon.", en: "satz needs access to the microphone.")
            case .couldNotConvertAudio:
                de("Das Mikrofon liefert ein Format, das satz nicht lesen kann.", en: "The microphone delivers a format satz cannot read.")
            case .engineFailed(let detail):
                de("Aufnahme fehlgeschlagen: \(detail)", en: "Recording failed: \(detail)")
            }
        }
    }

    public struct Settings: Sendable {
        /// gpt-transcribe is happy with 16 kHz mono, and it keeps uploads small.
        public var sampleRate: Double = 16_000
        /// How long the microphone stays open after `finish()` is called.
        public var tail: Duration = .milliseconds(400)
        /// Quietest level the waveform should show. Below this reads as silence.
        public var noiseFloorDecibels: Float = -55
        /// A Core Audio device ID to record from. nil uses the system's input.
        /// A plain UInt32 rather than AudioDeviceID, which does not exist on iOS.
        public var inputDeviceID: UInt32?

        public init() {}
    }

    /// Called on the main queue with a value in 0...1 while recording.
    public var onLevel: (@Sendable @MainActor (Float) -> Void)?
    /// Called on the main queue when the microphone stopped on its own and
    /// neither it nor the system's input would start again. What it heard
    /// until then stays: `finishSamples()` hands it over without a tail.
    public var onInputLost: (@Sendable @MainActor () -> Void)?
    /// Two monotonic timings per recording, delivered away from the audio
    /// thread. An engine that started may still be waiting for its first audio.
    public var onStartup: (@Sendable @MainActor (StartupTiming) -> Void)?

    /// Where a recording stands. Changed only on `lifecycle`.
    private enum State {
        case idle, running, lost, stopped
    }

    private let settings: Settings
    private let engine: any CaptureEngine
    private let askPermission: @Sendable () async -> Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    /// The samples, the converter and `lost`: the audio thread takes it too,
    /// so nothing that waits on the engine ever holds it.
    private let lock = NSLock()
    /// Start, restart after a route change, and stop run here one after the
    /// other. A restart that had passed its check while a cancel stopped the
    /// engine started it again after the cancel had returned, with nothing
    /// left that would ever stop it.
    private let lifecycle = DispatchQueue(label: "plus.dpa.satz.recorder")

    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var lost = false
    /// Cleared by the first converted buffer; route changes stay part of the
    /// same recording, so they cannot pretend to be its initial startup.
    private var awaitingFirstBufferSince: ContinuousClock.Instant?
    // Only touched on `lifecycle`.
    private var state = State.idle
    /// Counts starts, so a route change belongs to the start that heard it.
    private var generation = 0
    private var configurationObserver: NSObjectProtocol?

    public convenience init(settings: Settings = Settings()) {
        self.init(settings: settings, engine: AVAudioEngine(), permission: { await AudioRecorder.requestPermission() })
    }

    /// Tests put in an engine whose starts fail or wait on cue: a route change
    /// cannot be made to happen on demand, and a test never asks for the microphone.
    init(settings: Settings, engine: any CaptureEngine, permission: @escaping @Sendable () async -> Bool,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.settings = settings
        self.engine = engine
        askPermission = permission
        self.now = now
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Asks for microphone access, prompting the user the first time.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public func start() async throws {
        guard await askPermission() else { throw Failure.microphoneDenied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lifecycle.async { [self] in
                continuation.resume(with: Result { try begin() })
            }
        }
    }

    /// True once the microphone stopped on its own for good. Read by an owner
    /// that may have missed `onInputLost` because it was not listening yet.
    public var inputLost: Bool {
        lock.withLock { lost }
    }

    /// Stops after the tail has elapsed and returns the samples, for callers
    /// that join several recordings into one before sending. nil if the
    /// recording was cancelled or was not running.
    public func finishSamples() async -> [Float]? {
        switch await onLifecycle({ self.state }) {
        case .running: try? await Task.sleep(for: settings.tail)
        // Nothing comes in any more: no tail to wait for.
        case .lost: break
        case .idle, .stopped: return nil
        }
        return await onLifecycle { self.teardown(keeping: true) }
    }

    /// Samples captured so far, while still recording.
    public var sampleCount: Int {
        lock.withLock { samples.count }
    }

    /// A stretch of what has been captured so far, without stopping. Used to
    /// split a recording at a moment the user chose, with no gap at the cut.
    public func samples(from start: Int, to end: Int) -> [Float] {
        lock.withLock {
            let upper = min(end, samples.count)
            guard start < upper else { return [] }
            return Array(samples[max(0, start) ..< upper])
        }
    }

    /// Stops and discards everything captured. When it returns the engine is
    /// stopped, and no route change of this recording can start it again: it
    /// waits for one that is already starting it.
    public func cancel() {
        lifecycle.sync { _ = teardown(keeping: false) }
    }

    // MARK: - Lifecycle, on `lifecycle`

    private func begin() throws {
        guard state != .running, state != .lost else { return }
        let opening = now()
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            lost = false
            awaitingFirstBufferSince = opening
        }
        do {
            try open(device: settings.inputDeviceID)
        } catch {
            lock.withLock { awaitingFirstBufferSince = nil }
            throw error
        }
        report(startup: StartupTiming(stage: .engineStarted, elapsed: now() - opening))
        state = .running
        generation += 1
        let generation = generation, lifecycle = lifecycle, owner = Owner(self)
        // A new input (AirPods connecting) or the chosen one unplugged stops
        // the engine without a word: the card kept "listening" and every word
        // after it was lost. It starts again on what is there now, adding to
        // the same recording. The notification comes on the engine's own
        // queue, which a stopping engine can wait for: only the hop happens
        // there, and the recorder is not even held there, since freeing the
        // engine on that queue can deadlock (AVAudioEngine.h).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine as AnyObject, queue: nil
        ) { _ in
            lifecycle.async { owner.recorder?.restart(generation) }
        }
    }

    private func restart(_ heard: Int) {
        // Stopped since, or a later start's: not this restart's to undo.
        guard heard == generation, state == .running else { return }
        engine.stopCapture()
        do {
            try open(device: settings.inputDeviceID)
        } catch {
            do {
                // The chosen microphone is gone: the system's own instead.
                try open(device: Self.systemInput(insteadOf: settings.inputDeviceID))
            } catch {
                loseInput()
            }
        }
    }

    /// Neither the chosen input nor the system's would start. The samples
    /// stay for `finishSamples()`; the owner hears of it.
    private func loseInput() {
        state = .lost
        removeObserver()
        engine.stopCapture()
        lock.withLock { lost = true }
        guard let onInputLost else { return }
        Task { @MainActor in onInputLost() }
    }

    private func open(device: UInt32?) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: settings.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw Failure.couldNotConvertAudio }
        try engine.startCapture(device: device, ready: { format in
            guard let converter = AVAudioConverter(from: format, to: target) else { throw Failure.couldNotConvertAudio }
            // All channels mixed to one: by default the converter keeps channel 1
            // only, and a microphone on input 2 of an interface recorded silence.
            converter.downmix = true
            lock.withLock { self.converter = converter }
        }, buffer: { [weak self] buffer in
            self?.consume(buffer, into: target)
        })
    }

    /// Tears the engine down and hands back the captured samples, or nil if
    /// the recording was cancelled or is not running.
    private func teardown(keeping: Bool) -> [Float]? {
        guard state == .running || state == .lost else { return nil }
        state = .stopped
        removeObserver()
        engine.stopCapture()
        return lock.withLock {
            // Under the lock: the audio thread reads it under the same lock and
            // keeps its own strong reference for the buffer it is converting.
            converter = nil
            awaitingFirstBufferSince = nil
            defer { samples.removeAll(keepingCapacity: false) }
            return keeping ? samples : nil
        }
    }

    private func removeObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    private func onLifecycle<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            lifecycle.async { continuation.resume(returning: work()) }
        }
    }

    /// The system's input right now, for when the chosen one would not start.
    /// Said explicitly: nil sets no device, and the engine keeps the one it was
    /// given, the missing one. nil when none was chosen.
    private static func systemInput(insteadOf chosen: UInt32?) -> UInt32? {
        #if os(macOS)
        guard chosen != nil else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
        #else
        return nil
        #endif
    }

    // MARK: - Audio thread

    /// Runs on the audio thread. Converts to the target format, stores the
    /// samples, and reports loudness.
    private func consume(_ buffer: AVAudioPCMBuffer, into target: AVAudioFormat) {
        guard let converter = lock.withLock({ self.converter }) else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            // The converter asks repeatedly; hand over this buffer exactly once
            // and then report that the input has run dry.
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else { return }

        let frames = Int(converted.frameLength)
        let slice = UnsafeBufferPointer(start: channel, count: frames)

        let firstBuffer: StartupTiming? = lock.withLock {
            samples.append(contentsOf: slice)
            guard let opening = awaitingFirstBufferSince else { return nil }
            awaitingFirstBufferSince = nil
            return StartupTiming(stage: .firstBuffer, elapsed: now() - opening)
        }
        if let firstBuffer { report(startup: firstBuffer) }
        report(level: Self.level(of: slice, noiseFloor: settings.noiseFloorDecibels))
    }

    private func report(startup timing: StartupTiming) {
        guard let onStartup else { return }
        Task { @MainActor in onStartup(timing) }
    }

    private func report(level: Float) {
        guard let onLevel else { return }
        Task { @MainActor in onLevel(level) }
    }

    /// Root mean square of the block, mapped through decibels onto 0...1.
    /// Decibels rather than raw amplitude because loudness is perceived
    /// logarithmically: on a linear scale normal speech barely moves the bars.
    static func level(of samples: UnsafeBufferPointer<Float>, noiseFloor: Float) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        guard decibels > noiseFloor else { return 0 }
        return min(1, (decibels - noiseFloor) / -noiseFloor)
    }
}

/// A recorder held weakly, so the route-change handler never keeps it alive.
private final class Owner: @unchecked Sendable {
    weak var recorder: AudioRecorder?
    init(_ recorder: AudioRecorder) { self.recorder = recorder }
}

/// What the recorder needs from the audio hardware: `AVAudioEngine` in the
/// app. Its route-change notification is posted with the engine as object.
protocol CaptureEngine: AnyObject {
    /// Records from `device`, nil for the system's input. `ready` gets the
    /// device's format before the first buffer arrives, and may refuse it;
    /// `buffer` then gets every buffer, on the audio thread.
    func startCapture(device: UInt32?, ready: (AVAudioFormat) throws -> Void,
                      buffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    /// Removes the tap and stops. Harmless when nothing runs.
    func stopCapture()
}

extension AVAudioEngine: CaptureEngine {
    func startCapture(device: UInt32?, ready: (AVAudioFormat) throws -> Void,
                      buffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = inputNode
        #if os(macOS)
        // Must happen before the format is read: the format is the device's.
        if let deviceID = device, let unit = input.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<UInt32>.size)
            )
        }
        #endif
        let format = input.inputFormat(forBus: 0)
        try ready(format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { pcm, _ in buffer(pcm) }
        do {
            prepare()
            try start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorder.Failure.engineFailed(error.localizedDescription)
        }
    }

    func stopCapture() {
        inputNode.removeTap(onBus: 0)
        stop()
    }
}
