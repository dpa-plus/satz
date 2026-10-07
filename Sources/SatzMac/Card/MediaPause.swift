import AppKit
import Foundation

/// Pauses music and videos while the user dictates and plays them again when
/// the card closes: Spotify, Apple Music, YouTube in a browser, anything that
/// shows up under the system's Now Playing.
///
/// Only what is really playing gets paused, and only what satz paused is
/// played again: a song paused by hand a moment ago stays paused. The
/// system's Pause and Play are separate commands, never a toggle, so neither
/// can start something by mistake.
@MainActor
final class MediaPause {

    var isOn: () -> Bool = { true }
    /// Whether the pause at the start actually paused something.
    private var pausing: Task<Bool, Never>?

    func dictationStarted() {
        guard isOn(), pausing == nil else { return }
        pausing = Task.detached(priority: .userInitiated) {
            guard let state = NowPlaying.read(), state.playing else { return false }
            MediaCommand.send(.pause)
            Log.note("media paused (app \(state.pid))")
            return true
        }
    }

    func dictationEnded() {
        guard let pausing else { return }
        self.pausing = nil
        Task.detached(priority: .userInitiated) {
            guard await pausing.value else { return }
            // Something the user started in the meantime is theirs: leave it.
            if let state = NowPlaying.read(), state.playing { return }
            MediaCommand.send(.play)
            Log.note("media resumed")
        }
    }
}

/// What the system says is playing.
///
/// Since macOS 15.4 only Apple's own programs may read it; any other app is
/// told "nothing". So satz asks /usr/bin/perl, which is Apple's, to load a
/// small library that reads it (Resources/NowPlaying). Takes about 0.1 s.
enum NowPlaying {
    struct State: Decodable {
        let playing: Bool
        let pid: Int32
    }

    nonisolated static func read() -> State? {
        guard let script = Bundle.main.url(forResource: "now-playing", withExtension: "pl"),
              let library = libraryURL() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Never hold up a dictation for it.
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// A downloaded app's files carry the quarantine mark, and Perl would be
    /// refused a marked library. A copy written by satz itself carries none.
    nonisolated private static func libraryURL() -> URL? {
        guard let bundled = Bundle.main.url(forResource: "now-playing", withExtension: "dylib") else { return nil }
        guard getxattr(bundled.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return bundled }
        let copy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("satz/now-playing.dylib")
        guard let data = try? Data(contentsOf: bundled) else { return nil }
        if (try? Data(contentsOf: copy)) != data {
            try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: copy)) != nil else { return nil }
        }
        return copy
    }
}

/// The system's media commands, the same the keyboard's media keys send, but
/// as separate Pause and Play rather than a toggle.
enum MediaCommand: UInt32 {
    case play = 0
    case pause = 1

    nonisolated static func send(_ command: MediaCommand) {
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let symbol = dlsym(framework, "MRMediaRemoteSendCommand") else { return }
        _ = unsafeBitCast(symbol, to: Send.self)(command.rawValue, nil)
    }
}
