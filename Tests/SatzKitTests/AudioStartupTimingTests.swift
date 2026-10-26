import AVFoundation
import Foundation
import Testing
@testable import SatzKit

private final class StartupClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero

    func set(_ elapsed: Duration) { lock.withLock { self.elapsed = elapsed } }
    func now() -> ContinuousClock.Instant { lock.withLock { origin.advanced(by: elapsed) } }
}

private final class StartupEngine: CaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let clock: StartupClock
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    init(clock: StartupClock) { self.clock = clock }

    func startCapture(device: UInt32?, ready: (AVAudioFormat) throws -> Void,
                      buffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        try ready(format)
        lock.withLock { sink = buffer }
        clock.set(.milliseconds(200))
    }

    func stopCapture() { lock.withLock { sink = nil } }

    func emit(frames: Int) {
        guard let sink = lock.withLock({ sink }) else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0 ..< frames { buffer.floatChannelData![0][index] = 0 }
        sink(buffer)
    }

    func routeChanges() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
}

@MainActor
private func timingEventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite(.serialized) @MainActor
struct AudioStartupTimingTests {
    @Test func engineStartAndTheFirstCapturedBufferHaveSeparateTimings() async throws {
        let clock = StartupClock()
        let engine = StartupEngine(clock: clock)
        let recorder = AudioRecorder(settings: .init(), engine: engine, permission: { true }, now: { clock.now() })
        var timings: [AudioRecorder.StartupTiming] = []
        recorder.onStartup = { timings.append($0) }
        try await recorder.start()
        #expect(await timingEventually { timings.count == 1 })
        #expect(timings.first?.stage == .engineStarted)
        #expect(timings.first?.elapsed == .milliseconds(200))
        #expect(recorder.sampleCount == 0, "starting the engine does not mean audio has arrived")

        clock.set(.milliseconds(350))
        engine.emit(frames: 160)
        #expect(await timingEventually { timings.count == 2 })
        #expect(timings.last?.stage == .firstBuffer)
        #expect(timings.last?.elapsed == .milliseconds(350))
        #expect(recorder.sampleCount == 160, "silent but valid audio is captured too")
        engine.emit(frames: 160)
        // Callback delivery is asynchronous; allow a duplicate to arrive
        // before checking that later audio blocks remain unreported.
        try await Task.sleep(for: .milliseconds(20))
        recorder.cancel()
        #expect(timings.count == 2, "report only the first buffer, not each audio block")
    }

    @Test func anEmptyBufferIsNotReportedAsCapturedAudio() async throws {
        let clock = StartupClock()
        let engine = StartupEngine(clock: clock)
        let recorder = AudioRecorder(settings: .init(), engine: engine, permission: { true }, now: { clock.now() })
        var timings: [AudioRecorder.StartupTiming] = []
        recorder.onStartup = { timings.append($0) }
        try await recorder.start()
        #expect(await timingEventually { timings.count == 1 })
        clock.set(.milliseconds(300))
        engine.emit(frames: 0)
        clock.set(.milliseconds(500))
        engine.emit(frames: 160)
        #expect(await timingEventually { timings.count == 2 })
        #expect(timings.last?.stage == .firstBuffer)
        #expect(timings.last?.elapsed == .milliseconds(500), "the empty block must not claim the first-buffer timing")
        #expect(recorder.sampleCount == 160)
        recorder.cancel()
    }

    @Test func restartingForARouteChangeDoesNotRepeatTheInitialStartupTiming() async throws {
        let clock = StartupClock()
        let engine = StartupEngine(clock: clock)
        let recorder = AudioRecorder(settings: .init(), engine: engine, permission: { true }, now: { clock.now() })
        var timings: [AudioRecorder.StartupTiming] = []
        recorder.onStartup = { timings.append($0) }
        try await recorder.start()
        engine.emit(frames: 160)
        #expect(await timingEventually { timings.count == 2 })
        engine.routeChanges()
        // The lifecycle queue's next operation waits behind the restart.
        _ = await recorder.finishSamples()
        #expect(timings.count == 2)
    }

    @Test func permissionDenialNeverReportsThatTheEngineStarted() async {
        let clock = StartupClock()
        let engine = StartupEngine(clock: clock)
        let recorder = AudioRecorder(settings: .init(), engine: engine, permission: { false }, now: { clock.now() })
        var timings: [AudioRecorder.StartupTiming] = []
        recorder.onStartup = { timings.append($0) }
        do {
            try await recorder.start()
            Issue.record("permission denial unexpectedly started capture")
        } catch {
            #expect(error as? AudioRecorder.Failure == .microphoneDenied)
        }
        #expect(timings.isEmpty && recorder.sampleCount == 0)
    }
}
