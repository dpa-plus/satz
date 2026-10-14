import Foundation
import Testing
@testable import SatzMac

// F08 of the 14.10. bug hunt: the resume after one dictation had let go of its
// ownership before its read of what is playing came back, so a dictation that
// started meanwhile found the same player paused, took nothing, and the late
// Play started the music in the middle of it. A fake player, never the
// system's: a real Play would start the tester's own music.

/// One player, paused by satz. The read of the resume (the second one) waits
/// until the test lets it go, like the subprocess that really takes a while.
private final class SlowResumePlayers: @unchecked Sendable {
    private let lock = NSLock()
    private var playing = true
    private var log: [String] = []
    private var reads = 0
    private var held = false
    private let release = DispatchSemaphore(value: 0)

    var commands: [String] { lock.withLock { log } }
    var resumeReadIsHeld: Bool { lock.withLock { held } }
    var readCount: Int { lock.withLock { reads } }

    func read() -> NowPlaying.State? {
        let (number, isPlaying) = lock.withLock { () -> (Int, Bool) in reads += 1; return (reads, playing) }
        if number == 2 {
            lock.withLock { held = true }
            _ = release.wait(timeout: .now() + 5)
        }
        return NowPlaying.State(playing: isPlaying, pid: 100)
    }

    func send(_ command: MediaCommand) {
        lock.withLock {
            log.append(command == .play ? "play" : "pause")
            playing = command == .play
        }
    }

    func letTheResumeReadGo() { release.signal() }
}

@MainActor
private func eventually(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    return condition()
}

@Suite(.serialized) @MainActor
struct MediaResumeRaceTests {

    private func media(_ players: SlowResumePlayers) -> MediaPause {
        let media = MediaPause()
        media.nowPlaying = { players.read() }
        media.send = { players.send($0) }
        return media
    }

    @Test func aResumeStillReadingDoesNotPlayIntoTheNextDictation() async {
        let players = SlowResumePlayers()
        let media = media(players)
        media.dictationStarted()
        #expect(await eventually { players.commands == ["pause"] })

        // The first dictation ends; after the grace the resume reads what is
        // playing, and that read is slow.
        media.dictationEnded()
        #expect(await eventually { players.resumeReadIsHeld })

        // The second dictation starts while the read is out, then the read returns.
        media.dictationStarted()
        players.letTheResumeReadGo()
        try? await Task.sleep(for: .milliseconds(400))

        // Paused it was, paused it stays: nobody is to hear music while talking.
        #expect(players.commands == ["pause"])
    }

    @Test func theMusicStillComesBackWhenTheSecondDictationEnds() async {
        let players = SlowResumePlayers()
        let media = media(players)
        media.dictationStarted()
        #expect(await eventually { players.commands == ["pause"] })
        media.dictationEnded()
        #expect(await eventually { players.resumeReadIsHeld })
        media.dictationStarted()
        players.letTheResumeReadGo()
        try? await Task.sleep(for: .milliseconds(200))

        // The ownership was handed over, not dropped: once, after the second one.
        media.dictationEnded()
        #expect(await eventually { players.commands == ["pause", "play"] })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(players.commands == ["pause", "play"])
    }

    @Test func aResumeThatIsNotInterruptedStillPlays() async {
        let players = SlowResumePlayers()
        let media = media(players)
        media.dictationStarted()
        #expect(await eventually { players.commands == ["pause"] })
        media.dictationEnded()
        #expect(await eventually { players.resumeReadIsHeld })
        players.letTheResumeReadGo()
        #expect(await eventually { players.commands == ["pause", "play"] })
    }
}
