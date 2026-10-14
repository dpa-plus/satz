import AppKit
import SatzKit

/// Remote control for testing satz without a keyboard or a microphone.
///
/// Only listens when launched with `--dev-control <state file>`. Commands
/// arrive as distributed notifications named `plus.dpa.satz.dev`, with the
/// command as the object, prefixed with `@<state file>|` to reach one copy
/// only: `press`, `release`, `mic`, `discard`, `undo`,
/// `caret:<index>` (as if clicked there), `field` (logs where the focused
/// text field is), `dump`, which writes the card's
/// phase and text to the state file, `picture`, which saves the live
/// card as a PNG next to it, `film`, which toggles the eye and saves a
/// picture of every step of the animation, `clipboard`, which checks on
/// a private pasteboard that a paste hands every kind of content back,
/// `strand`, which leaves the card's window on one other desktop, and
/// `settings`, `setup`, `history`, `menu` and `close` for satz's own windows,
/// `download:<model>`, `cancel:<model>`, `measure:<model>`, `use:<model>`
/// and `local:<model>` for a model on this Mac (its download, stopping it,
/// its speed test, dictating with it, its state), `cleanup:on`, `cleanup:off`,
/// `cleanup-level:<id>`, `cleanup-provider:<id>` (the one in use, and then
/// the one shown), `cleanup-model:<id>` and `cleanup-address:<url>` (for the
/// provider shown) and `cleanup-try` (Ausprobieren with the sample, into
/// `dump`'s `cleanupTry`; a bad argument is logged and ignored), and `quit`,
/// which quits the way the menu does. Downloads need `--models-dir <folder>`:
/// a test never fills or empties the user's own models folder. Cleanup goes
/// only to this computer (a stand-in server, Apple's model) unless the copy is
/// started with `--test-cleanup-remote`: the key files are the real satz's.
@MainActor
final class DevControl {

    private let session: Session
    private let card: CardController
    private let stateFile: URL
    private var observer: NSObjectProtocol?
    private var delivered: [String] = []
    /// Commands came addressed to this copy (`@<state file>|…`).
    private var addressed = false
    /// The eye button, from the app's preferences.
    var toggleEye: () -> Void = {}
    /// Opens satz's own windows: "settings", "setup", "menu"; "close" closes them.
    var open: (String) -> Void = { _ in }
    /// The language set in Settings, which Canary and Apple's listen for.
    var spoken: () -> Language = { .german }
    /// What clicking one of "Your models" does: the model, and Lokal, in use.
    var use: (String) -> Void = { _ in }
    /// For the cleanup commands. A test copy never calls a real provider
    /// unless the test points it at one: the commands are how it does.
    var preferences: Preferences?
    var cleanups: CleanupStore?

    init(session: Session, card: CardController, stateFile: URL) {
        self.session = session
        self.card = card
        self.stateFile = stateFile
        // Never paste during a test: the text would land in whatever app the
        // person at the Mac is using.
        session.deliverOverride = { [weak self] text in
            self?.delivered.append(text)
            self?.dump()
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("plus.dpa.satz.dev"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
        Log.note("dev control on")
    }

    private func run(_ command: String) {
        // "@<state file>|press" is for this copy only: a command goes to
        // every test copy listening, and two at once drove each other.
        // Once a script talks to it that way, it takes nothing else: another
        // session's `quit` stopped this copy halfway through a test.
        var command = command
        if command.hasPrefix("@") {
            guard let bar = command.firstIndex(of: "|"), command[command.index(after: command.startIndex) ..< bar] == stateFile.path else { return }
            command = String(command[command.index(after: bar)...])
            addressed = true
        } else if addressed {
            return Log.note("dev: \(command) ignored, this copy takes its own commands only")
        }
        Log.note("dev: \(command)")
        switch command {
        case "press": session.press()
        case "release": session.release()
        case "mic": session.toggleMicrophone()
        case "discard": session.discard()
        case "undo": session.undoDiscard()
        case "dump": dump()
        case "eye": toggleEye()
        case "settings", "setup", "history", "menu", "close": open(command)
        case "strand": strand()
        case "quit": NSApp.terminate(nil)
        case "field": Log.note("focused field: \(FocusedField.frame().map { NSStringFromRect($0) } ?? "unknown"), editable \(FocusedField.isEditable(in: Session.frontmostOtherApp())) in \(Session.frontmostOtherApp()?.localizedName ?? "?")")
        case "picture":
            try? card.picture()?.write(to: stateFile.deletingPathExtension().appendingPathExtension("png"))
        case "film": film()
        case "clipboard": checkClipboard()
        default:
            if command.hasPrefix("caret:"), let index = Int(command.dropFirst(6)) {
                session.userMovedCaret(to: index)
            } else if command.hasPrefix("download:") {
                // What clicking an available model in Settings does.
                LocalModels.shared.download(String(command.dropFirst(9)), language: spoken())
            } else if command.hasPrefix("cancel:") {
                LocalModels.shared.cancel(String(command.dropFirst(7)))
            } else if command.hasPrefix("measure:") {
                // What clicking the speed bar of a model on this Mac does.
                LocalModels.shared.measure(String(command.dropFirst(8)), language: spoken())
            } else if command.hasPrefix("use:") {
                use(String(command.dropFirst(4)))
                dump()
            } else if command.hasPrefix("cleanup") {
                cleanup(command)
            } else if command.hasPrefix("local:") {
                let model = String(command.dropFirst(6))
                let local = LocalModels.shared
                // What Settings asks when the list appears: once a run.
                local.refreshSupport()
                let speed = local.speeds[model].map { String(format: "%.2f s per 10 s", $0.secondsPer10) } ?? "not measured"
                Log.note("local: \(model) is \(local.state(of: model, language: spoken())), \(local.measuring.contains(model) ? "measuring" : speed), in memory: \(local.inMemory.loaded ?? "none") (+ \(local.inMemory.spare ?? "no spare"))")
                dump()
            }
        }
    }

    /// A value for the state file, null when there is none.
    static func json(_ value: Any?) -> Any { value ?? NSNull() }

    /// The cleanup settings, as Settings would change them. A bad argument is
    /// logged and ignored, the same on Windows and Linux.
    private func cleanup(_ command: String) {
        guard let preferences, let cleanups else { return }
        let parts = command.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : ""
        // `cleanup-model` and `cleanup-address` are for the provider Settings shows.
        let shown = cleanups.shown(preferences)
        switch name {
        case "cleanup":
            guard value == "on" || value == "off" else { return Log.note("dev: cleanup takes on or off, ignored") }
            preferences.cleansText = value == "on"
        case "cleanup-level":
            guard let level = CleanupLevel(rawValue: value) else { return Log.note("dev: \(value) is no cleanup level, ignored") }
            // As choosing it in Settings: the own prompt starts with the level before.
            preferences.chooseCleanupLevel(level)
        case "cleanup-provider":
            guard let provider = CleanupProvider(rawValue: value) else { return Log.note("dev: \(value) is no cleanup provider, ignored") }
            // The one in use, and the one Settings shows.
            preferences.cleanupProvider = provider
            cleanups.looking = nil
        case "cleanup-model": preferences.setCleanupModel(value, for: shown)
        case "cleanup-address": preferences.setCleanupAddress(value, for: shown)
        case "cleanup-try":
            cleanups.tryOut(CleanupSample.text(for: spoken()), preferences) { [weak self] in self?.dump() }
        default: return Log.note("dev: unknown cleanup command, ignored")
        }
        Log.note("cleanup: \(preferences.cleansText ? "on" : "off"), \(preferences.cleanupLevel.rawValue), \(preferences.cleanupProvider.rawValue) \(cleanups.modelID(preferences.cleanupProvider, preferences))")
        dump()
    }

    /// Toggles the eye and saves a picture every 40 ms while the card
    /// animates (state-film-0.png, -1, ...), to see each step of it.
    private func film() {
        toggleEye()
        let base = stateFile.deletingPathExtension().path
        for step in 0 ..< 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(step * 40)) { [card] in
                try? card.picture()?.write(to: URL(fileURLWithPath: "\(base)-film-\(step).png"))
            }
        }
    }

    /// Puts a picture and a styled text on a private pasteboard, does what a
    /// paste does to the clipboard, and logs whether everything came back.
    /// Never the real clipboard.
    private func checkClipboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("plus.dpa.satz.test"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(NSImage(size: NSSize(width: 4, height: 4)).tiffRepresentation ?? Data(), forType: .tiff)
        item.setString("copied", forType: .string)
        item.setData(Data("{\\rtf1 copied}".utf8), forType: .rtf)
        board.writeObjects([item])
        let before = Set(board.pasteboardItems?.first?.types ?? [])
        let saved = Paster.copy(of: board)
        board.clearContents()
        board.setString("transcript", forType: .string)
        Paster.putBack(saved, on: board, ifStill: board.changeCount)
        let after = Set(board.pasteboardItems?.first?.types ?? [])
        let restored = board.string(forType: .string) ?? "-"
        // Something copied after the paste must not be overwritten.
        let copiedLater = board.changeCount
        board.clearContents()
        board.setString("newer", forType: .string)
        Paster.putBack(saved, on: board, ifStill: copiedLater)
        Log.note("clipboard: types back \(before == after) (\(after.count) of \(before.count)), text \(restored), newer kept \(board.string(forType: .string) == "newer")")
        board.releaseGlobally()
    }

    /// Leaves the card's window on one desktop the user is not on, the state
    /// it was found in after a night's sleep, so `press` can show that satz
    /// gets out of it. Through the window server's private calls, which only
    /// the window's own app may make on it.
    private func strand() {
        typealias Connection = @convention(c) () -> Int32
        typealias Spaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        typealias Active = @convention(c) (Int32) -> UInt64
        typealias Remove = @convention(c) (Int32, CFArray, CFArray) -> Void
        guard let number = card.windowNumber,
              let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(sky, "SLSMainConnectionID"), let s = dlsym(sky, "SLSCopySpacesForWindows"),
              let a = dlsym(sky, "SLSGetActiveSpace"), let r = dlsym(sky, "SLSRemoveWindowsFromSpaces")
        else { return Log.note("strand: no card window yet") }
        let connection = unsafeBitCast(c, to: Connection.self)()
        let spacesOf = { (unsafeBitCast(s, to: Spaces.self)(connection, 7, [number] as CFArray)?.takeRetainedValue() as? [UInt64]) ?? [] }
        let active = unsafeBitCast(a, to: Active.self)(connection)
        guard let keep = spacesOf().first(where: { $0 != active }) else { return Log.note("strand: only one desktop") }
        unsafeBitCast(r, to: Remove.self)(connection, [number] as CFArray, spacesOf().filter { $0 != keep } as CFArray)
        Log.note("strand: card window now on desktops \(spacesOf()), active \(active)")
    }

    /// What is in memory, what is being timed, and every speed measured.
    private func localState() -> [String: Any] {
        let local = LocalModels.shared
        return [
            "folder": LocalModels.root.path,
            "states": Dictionary(uniqueKeysWithValues: LocalCatalog.all.map { ($0.id, String(describing: local.state(of: $0.id, language: spoken()))) }),
            "loaded": local.inMemory.loaded ?? NSNull(),
            "spare": local.inMemory.spare ?? NSNull(),
            "measuring": local.measuring.sorted(),
            "speeds": local.speeds.mapValues { ["secondsPer10": $0.secondsPer10, "machine": $0.machine, "version": $0.version,
                                                "measured": ISO8601DateFormatter().string(from: $0.measured)] },
        ]
    }

    /// The state file's `cleanup`: the last dictation's, absent when cleanup was
    /// off for it. `outcome` is "ok" or a stable code (`CleanupFailure.code`),
    /// `reason` the localized short reason and absent on "ok", `cleaned` what
    /// the model answered (also when it was not used, nil when nothing came
    /// back). The same shape on Windows and Linux.
    static func cleanupState(_ record: Session.CleanupRecord) -> [String: Any] {
        var state: [String: Any] = [
            "outcome": record.outcome,
            "original": record.original,
            "cleaned": json(record.cleaned),
            "provider": json(record.provider),
            "model": json(record.model),
            "seconds": json(record.seconds),
        ]
        if let failure = record.failure { state["reason"] = failure.short() }
        return state
    }

    /// The state file's `cleanupTry`: the keys of `cleanup` (but for `original`),
    /// `rejected` (the guard threw the answer out) and `dollars`.
    static func tryState(_ tried: CleanupStore.Tried) -> [String: Any] {
        var state: [String: Any] = [
            "provider": tried.provider.rawValue,
            "model": tried.model,
            "outcome": tried.result.failure?.code ?? "ok",
            "cleaned": json(tried.result.cleaned),
            "rejected": tried.result.failure == .rejected,
            "seconds": json(tried.result.seconds),
            "dollars": json(tried.result.dollars),
        ]
        if let failure = tried.result.failure { state["reason"] = failure.short() }
        return state
    }

    /// Not private so a test can ask for the state without a notification.
    func dump() {
        var state: [String: Any] = [
            "phase": String(describing: session.phase),
            // A pause the microphone caused (unplugged), which the card says in words.
            "microphoneLost": session.microphoneLost,
            "cleaning": session.isCleaning,
            "text": session.plainText(),
            "raw": session.text.string,
            "sending": session.inFlight.count,
            "delivered": delivered,
            "window": card.frameDescription,
            "local": localState(),
        ]
        if let record = session.lastCleanup { state["cleanup"] = Self.cleanupState(record) }
        if let preferences {
            state["cleanupSettings"] = [
                "on": preferences.cleansText,
                "level": preferences.cleanupLevel.rawValue,
                "provider": preferences.cleanupProvider.rawValue,
                "model": cleanups?.modelID(preferences.cleanupProvider, preferences) ?? "",
                "address": preferences.cleanupAddress(for: preferences.cleanupProvider),
            ]
        }
        if let tried = cleanups?.tried {
            state["cleanupTry"] = Self.tryState(tried)
        } else if cleanups?.trying == true {
            state["cleanupTry"] = "running"
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateFile)
        }
    }
}
