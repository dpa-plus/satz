import AppKit

/// Remote control for testing satz without a keyboard or a microphone.
///
/// Only listens when launched with `--dev-control <state file>`. Commands
/// arrive as distributed notifications named `plus.dpa.satz.dev`, with the
/// command as the object: `press`, `release`, `mic`, `discard`, `undo`,
/// `caret:<index>` (as if clicked there), `field` (logs where the focused
/// text field is), `dump`, which writes the card's
/// phase and text to the state file, `picture`, which saves the live
/// card as a PNG next to it, `film`, which toggles the eye and saves a
/// picture of every step of the animation, `clipboard`, which checks on
/// a private pasteboard that a paste hands every kind of content back,
/// `strand`, which leaves the card's window on one other desktop, and
/// `settings`, `setup`, `history`, `menu` and `close` for satz's own windows,
/// and `quit`, which quits the way the menu does.
@MainActor
final class DevControl {

    private let session: Session
    private let card: CardController
    private let stateFile: URL
    private var observer: NSObjectProtocol?
    private var delivered: [String] = []
    /// The eye button, from the app's preferences.
    var toggleEye: () -> Void = {}
    /// Opens satz's own windows: "settings", "setup", "menu"; "close" closes them.
    var open: (String) -> Void = { _ in }

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
        case "field": Log.note("focused field: \(FocusedField.frame().map { NSStringFromRect($0) } ?? "unknown")")
        case "picture":
            try? card.picture()?.write(to: stateFile.deletingPathExtension().appendingPathExtension("png"))
        case "film": film()
        case "clipboard": checkClipboard()
        default:
            if command.hasPrefix("caret:"), let index = Int(command.dropFirst(6)) {
                session.userMovedCaret(to: index)
            }
        }
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

    private func dump() {
        let state: [String: Any] = [
            "phase": String(describing: session.phase),
            "text": session.plainText(),
            "raw": session.text.string,
            "sending": session.inFlight.count,
            "delivered": delivered,
            "window": card.frameDescription,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateFile)
        }
    }
}
