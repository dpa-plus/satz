import AppKit
import Foundation

/// Pauses music and videos while the user dictates and plays them again when
/// the card closes: Spotify, Apple Music, YouTube in a browser, anything that
/// shows up under the system's Now Playing.
///
/// Only what is really playing gets paused, and only what satz paused is
/// played again: a song paused by hand a moment ago stays paused, and so does
/// any other player that became the system's current one meanwhile. The
/// system's Pause and Play are separate commands, never a toggle, so neither
/// can start something by mistake.
@MainActor
final class MediaPause {

    var isOn: () -> Bool = { true }
    /// What the system says is playing, and how to pause and play it. Tests
    /// replace both: a real Play would start the tester's own music.
    var nowPlaying: @Sendable () -> NowPlaying.State? = { NowPlaying.read() }
    var send: @Sendable (MediaCommand) -> Void = { MediaCommand.send($0) }
    /// The app satz paused and has not played again yet. The system's Play
    /// goes to whichever player is current, not to this one, so it is checked
    /// before every Play.
    private var pausedPlayer: Int32?
    private var pausing: Task<Void, Never>?
    /// Kept until the resume has sent its Play, not only through the grace:
    /// reading what is current takes a subprocess, and a dictation that starts
    /// meanwhile has to be able to call the Play off.
    private var resuming: Task<Void, Never>?

    func dictationStarted() {
        // The next dictation right after the last one: the music stays paused.
        resuming?.cancel()
        resuming = nil
        guard isOn(), pausedPlayer == nil, pausing == nil else { return }
        let read = nowPlaying, send = send
        pausing = Task {
            let paused = await Task.detached(priority: .userInitiated) { () -> Int32? in
                guard let state = read(), state.playing else { return nil }
                send(.pause)
                Log.note("media paused (app \(state.pid))")
                return state.pid
            }.value
            pausedPlayer = paused
            pausing = nil
        }
    }

    func dictationEnded() {
        let pausing = self.pausing
        resuming?.cancel()
        resuming = Task {
            await pausing?.value
            // A moment's grace: two dictations in a row did play-pause between them.
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let player = pausedPlayer else { return }
            let read = nowPlaying
            let current = await Task.detached(priority: .userInitiated) { read() }.value
            // Back on the main actor, where a dictation starts: a new one
            // began while the read ran (cancelled), and the music has to stay
            // paused for it. Nothing can start between this check and the Play.
            guard !Task.isCancelled else { return }
            pausedPlayer = nil
            resuming = nil
            Self.play(player, current: current, send: send)
        }
    }

    /// satz quits: what it paused plays again, also in the middle of a dictation.
    func quitting() {
        resuming?.cancel()
        guard let player = pausedPlayer else { return }
        pausedPlayer = nil
        guard Self.play(player, current: nowPlaying(), send: send) else { return }
        // The command is delivered after the call returns; a process that
        // exits at once never sends it.
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Plays `player` again if `state`, what the system showed, says it is
    /// still current and paused. True when the command went out.
    @discardableResult
    nonisolated private static func play(_ player: Int32, current state: NowPlaying.State?, send: (MediaCommand) -> Void) -> Bool {
        // Not knowing what is current is not a reason to play: Play goes to
        // whatever is, and that may be something else.
        guard let state else {
            Log.note("media not resumed, could not read what is current")
            return false
        }
        // Something the user started in the meantime is theirs: leave it.
        if state.playing {
            Log.note("media left as the user set it")
            return false
        }
        guard state.pid == player else {
            Log.note("media not resumed, app \(state.pid) is current now, not app \(player)")
            return false
        }
        send(.play)
        Log.note("media resumed")
        return true
    }
}
