import AVFoundation
import Foundation
import Testing
@testable import SatzKit

// I-2 and I-3 of Codex's third bug hunt (14.10.). A microphone gone for good
// went quiet without a word while the card kept listening; a route change
// already under way when the recording stopped started the engine again, with
// nothing left that would ever stop it. No microphone is opened and no
// permission asked: the engine is a stand-in whose starts fail or wait on
// cue, and the route change is the real notification, posted from another
// queue as AVAudioEngine does.

private final class Gate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
}

private final class StandInEngine: CaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Bool]
    private var attempts: [UInt32?] = []
    private var running = false
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var nextStopGate: Gate?
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// - Parameter outcomes: whether each start works, in order; then all do.
    init(outcomes: [Bool] = []) { self.outcomes = outcomes }

    func startCapture(device: UInt32?, ready: (AVAudioFormat) throws -> Void,
                      buffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let works = lock.withLock { () -> Bool in
            attempts.append(device)
            return outcomes.isEmpty ? true : outcomes.removeFirst()
        }
        try ready(format)
        guard works else { throw AudioRecorder.Failure.engineFailed("stand-in input gone") }
        lock.withLock {
            running = true
            sink = buffer
        }
    }

    func stopCapture() {
        let gate = lock.withLock { () -> Gate? in
            defer { nextStopGate = nil }
            return nextStopGate
        }
        if let gate {
            gate.entered.signal()
            _ = gate.proceed.wait(timeout: .now() + 10)
        }
        lock.withLock {
            running = false
            sink = nil
        }
    }

    /// The next stop waits there until the test lets it go on.
    func holdNextStop(_ gate: Gate) { lock.withLock { nextStopGate = gate } }
    var isRunning: Bool { lock.withLock { running } }
    var starts: Int { lock.withLock { attempts.count } }

    /// Someone speaks: one buffer, as the tap would hand it over.
    func speak(_ frames: Int) {
        guard let sink = lock.withLock({ sink }) else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0 ..< frames { buffer.floatChannelData![0][index] = 0.2 * sinf(Float(index) / 4) }
        sink(buffer)
    }

    /// What AVAudioEngine posts, on a queue of its own, when the input changes.
    func routeChanges() {
        DispatchQueue.global().async { [self] in
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
        }
    }
}

@MainActor
private final class Told {
    var lost = 0
}

private func recorder(_ engine: StandInEngine, tail: Duration = .milliseconds(50)) -> AudioRecorder {
    var settings = AudioRecorder.Settings()
    // A chosen microphone, so the fallback to the system's own is a second try.
    settings.inputDeviceID = 42
    settings.tail = tail
    return AudioRecorder(settings: settings, engine: engine, permission: { true })
}

@MainActor
private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Waits off the main thread, so the callbacks it waits for can still arrive there.
private func wait(_ semaphore: DispatchSemaphore, _ seconds: Double) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
        }
    }
}

@Suite(.serialized) @MainActor
struct CodexR3RecorderTests {

    // MARK: I-2: gone for good

    @Test func aMicrophoneGoneForGoodIsSaidAndWhatItHeardIsKept() async throws {
        // Started, then after the route change neither the chosen input nor the system's.
        let engine = StandInEngine(outcomes: [true, false, false])
        let recorder = recorder(engine, tail: .seconds(2))
        let told = Told()
        recorder.onInputLost = { told.lost += 1 }
        try await recorder.start()
        engine.speak(1600)
        engine.routeChanges()
        #expect(await eventually { told.lost == 1 }, "the owner never heard the microphone was gone")
        #expect(recorder.inputLost)
        #expect(!engine.isRunning && engine.starts == 3)
        // Finishing hands over what it heard, without a tail into a dead input.
        let asked = ContinuousClock.now
        let samples = await recorder.finishSamples()
        #expect(samples?.count == 1600)
        #expect(ContinuousClock.now - asked < .seconds(1))
        // And nothing of it starts again.
        engine.routeChanges()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(engine.starts == 3 && !engine.isRunning && told.lost == 1)
    }

    @Test func theSystemsInputTakingOverIsNoLoss() async throws {
        let engine = StandInEngine(outcomes: [true, false, true])
        let recorder = recorder(engine)
        let told = Told()
        recorder.onInputLost = { told.lost += 1 }
        try await recorder.start()
        engine.speak(800)
        engine.routeChanges()
        #expect(await eventually { engine.starts == 3 && engine.isRunning })
        engine.speak(800)
        // One recording, before and after the change.
        #expect(await recorder.finishSamples()?.count == 1600)
        #expect(!recorder.inputLost && told.lost == 0 && !engine.isRunning)
    }

    // MARK: I-3: a restart belongs to the recording that heard it

    @Test func aRestartUnderWayWhenCancelComesIsStoppedBeforeCancelReturns() async throws {
        let engine = StandInEngine()
        let recorder = recorder(engine)
        try await recorder.start()
        let restart = Gate()
        engine.holdNextStop(restart)
        engine.routeChanges()
        #expect(await wait(restart.entered, 5), "the restart never began")
        // The × while the restart is half done.
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recorder.cancel()
            cancelled.signal()
        }
        // It waits for the restart instead of running beside it.
        #expect(!(await wait(cancelled, 0.3)), "cancel returned while a restart was still starting the engine")
        restart.proceed.signal()
        #expect(await wait(cancelled, 5))
        #expect(!engine.isRunning, "a restart started the engine again after cancel had returned")
        // Cancelling again, or a later change, leaves it off.
        recorder.cancel()
        engine.routeChanges()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!engine.isRunning && engine.starts == 2)
    }

    @Test func aRestartUnderWayWhenFinishComesIsStoppedBeforeFinishReturns() async throws {
        let engine = StandInEngine()
        let recorder = recorder(engine)
        try await recorder.start()
        engine.speak(1600)
        let restart = Gate()
        engine.holdNextStop(restart)
        engine.routeChanges()
        #expect(await wait(restart.entered, 5))
        let finished = Task { await recorder.finishSamples() }
        // Let the restart go on once finishing is over, or after half a second.
        let done = DispatchSemaphore(value: 0)
        Task {
            _ = await finished.value
            done.signal()
        }
        _ = await wait(done, 0.5)
        restart.proceed.signal()
        let samples = await finished.value
        #expect(samples?.count == 1600)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!engine.isRunning, "a restart started the engine again after finishing had returned")
        engine.routeChanges()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!engine.isRunning && engine.starts == 2)
    }

    @Test func aRouteChangeQueuedBehindTheStopStartsNothing() async throws {
        let engine = StandInEngine()
        let recorder = recorder(engine)
        try await recorder.start()
        let first = Gate()
        engine.holdNextStop(first)
        engine.routeChanges()
        #expect(await wait(first.entered, 5))
        // The cancel waits behind the first restart; a second change is heard
        // while it waits, so its restart comes after the stop.
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recorder.cancel()
            cancelled.signal()
        }
        try? await Task.sleep(for: .milliseconds(150))
        engine.routeChanges()
        try? await Task.sleep(for: .milliseconds(150))
        first.proceed.signal()
        #expect(await wait(cancelled, 5))
        try? await Task.sleep(for: .milliseconds(300))
        // The first restart's start and nothing after the stop.
        #expect(engine.starts == 2 && !engine.isRunning)
    }

    @Test func aRouteChangeAfterCancelStartsNothing() async throws {
        let engine = StandInEngine()
        let recorder = recorder(engine)
        try await recorder.start()
        recorder.cancel()
        engine.routeChanges()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(engine.starts == 1 && !engine.isRunning)
        #expect(await recorder.finishSamples() == nil)
    }
}
