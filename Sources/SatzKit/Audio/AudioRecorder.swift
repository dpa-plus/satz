import AVFoundation
import Foundation

/// Captures the microphone into 16 kHz mono samples and reports a loudness
/// level while it does, so the interface can draw a waveform.
///
/// Two behaviours here are deliberate rather than incidental:
///
/// - `finish()` keeps the microphone open for `Settings.tail` after it is
///   called. Stopping the instant the key is released clips the last word,
///   which is the most common complaint about dictation tools.
/// - `cancel()` throws the audio away without ever producing a file, so a
///   cancelled recording cannot be uploaded by a later mistake.
public final class AudioRecorder: @unchecked Sendable {

    public enum Failure: Error, LocalizedError, Equatable {
        case microphoneDenied
        case couldNotConvertAudio
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "satz braucht Zugriff auf das Mikrofon."
            case .couldNotConvertAudio:
                "Das Mikrofon liefert ein Format, das satz nicht lesen kann."
            case .engineFailed(let detail):
                "Aufnahme fehlgeschlagen: \(detail)"
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

        public init() {}
    }

    /// Called on the main queue with a value in 0...1 while recording.
    public var onLevel: (@Sendable @MainActor (Float) -> Void)?

    private let settings: Settings
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var isCancelled = false
    private var isRunning = false

    public init(settings: Settings = Settings()) {
        self.settings = settings
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
        guard await Self.requestPermission() else { throw Failure.microphoneDenied }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            isCancelled = false
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: settings.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw Failure.couldNotConvertAudio
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, into: target)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineFailed(error.localizedDescription)
        }
        lock.withLock { isRunning = true }
    }

    /// Stops after the tail has elapsed and returns the recording as WAV bytes.
    /// Returns `nil` if the recording was cancelled, or if it captured nothing.
    public func finish() async -> Data? {
        guard lock.withLock({ isRunning }) else { return nil }
        try? await Task.sleep(for: settings.tail)

        let captured = teardown()
        guard let captured, !captured.isEmpty else { return nil }
        return WAVEncoder.encode(samples: captured, sampleRate: Int(settings.sampleRate))
    }

    /// Stops immediately and discards everything captured.
    public func cancel() {
        lock.withLock { isCancelled = true }
        _ = teardown()
    }

    // MARK: - Private

    /// Tears the engine down and hands back the captured samples, or nil if the
    /// recording was cancelled.
    private func teardown() -> [Float]? {
        guard lock.withLock({ isRunning }) else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        return lock.withLock {
            isRunning = false
            defer { samples.removeAll(keepingCapacity: false) }
            return isCancelled ? nil : samples
        }
    }

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

        lock.withLock { samples.append(contentsOf: slice) }
        report(level: Self.level(of: slice, noiseFloor: settings.noiseFloorDecibels))
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
