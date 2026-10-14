import Foundation
import SatzKit

/// What a dictation records from: the microphone, or in test mode a file
/// that plays as if someone were speaking it.
protocol AudioSource: AnyObject, Sendable {
    var onLevel: (@Sendable @MainActor (Float) -> Void)? { get set }
    /// The input stopped on its own and could not be started again. What it
    /// heard stays, and `finishSamples()` still hands it over.
    var onInputLost: (@Sendable @MainActor () -> Void)? { get set }
    /// The same, for an owner that was not listening yet when it happened.
    var inputLost: Bool { get }
    func start() async throws
    func finishSamples() async -> [Float]?
    var sampleCount: Int { get }
    func samples(from start: Int, to end: Int) -> [Float]
    func cancel()
}

extension AudioRecorder: AudioSource {}

enum AudioSources {
    /// Files to play instead of the microphone, one per recording, in order.
    /// Set by `--test-audio a.wav:b.wav`; nil in normal use.
    @MainActor static var testFiles: [URL]?

    @MainActor
    static func make(inputDeviceUID: String?) -> AudioSource {
        if var files = testFiles {
            // Once they run out, silence: a test never records the room. It
            // once took the microphone and wrote down what the user said to
            // their own satz.
            let next = files.isEmpty ? URL(fileURLWithPath: "/dev/null") : files.removeFirst()
            testFiles = files
            return FileSource(url: next)
        }
        var settings = AudioRecorder.Settings()
        settings.inputDeviceID = InputDevices.id(forUID: inputDeviceUID)
        return AudioRecorder(settings: settings)
    }
}

/// Plays a 16 kHz mono WAV in real time: `sampleCount` grows with the clock,
/// and the levels move, exactly like the microphone would.
final class FileSource: AudioSource, @unchecked Sendable {
    var onLevel: (@Sendable @MainActor (Float) -> Void)?
    /// A file never comes unplugged.
    var onInputLost: (@Sendable @MainActor () -> Void)?
    var inputLost: Bool { false }

    private let samples: [Float]
    private let lock = NSLock()
    private var startedAt: Date?
    private var stoppedAt: Int?
    private var ticker: Task<Void, Never>?

    init(url: URL) {
        // Read by its chunks: afconvert puts a padding chunk before the
        // audio, and a clip read as a plain 44-byte header played nothing.
        samples = (try? Data(contentsOf: url)).flatMap(WAVDecoder.decode)?.samples ?? []
    }

    func start() async throws {
        lock.withLock { startedAt = Date() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self else { return }
                let end = self.sampleCount
                let window = self.samples(from: max(0, end - 960), to: end)
                let rms = window.isEmpty ? 0 : (window.map { $0 * $0 }.reduce(0, +) / Float(window.count)).squareRoot()
                let level = rms > 0 ? max(0, min(1, (20 * log10(rms) + 55) / 55)) : 0
                if let onLevel = self.onLevel { await onLevel(level) }
            }
        }
    }

    var sampleCount: Int {
        lock.withLock {
            if let stoppedAt { return stoppedAt }
            guard let startedAt else { return 0 }
            return min(samples.count, Int(Date().timeIntervalSince(startedAt) * 16_000))
        }
    }

    func samples(from start: Int, to end: Int) -> [Float] {
        let upper = min(end, samples.count)
        guard start < upper else { return [] }
        return Array(samples[max(0, start) ..< upper])
    }

    func finishSamples() async -> [Float]? {
        try? await Task.sleep(for: .milliseconds(400))
        ticker?.cancel()
        let end = sampleCount
        lock.withLock { stoppedAt = end }
        return samples(from: 0, to: end)
    }

    func cancel() {
        ticker?.cancel()
        lock.withLock { stoppedAt = 0 }
    }
}
