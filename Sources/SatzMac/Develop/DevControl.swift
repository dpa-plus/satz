import AppKit

/// Remote control for testing satz without a keyboard or a microphone.
///
/// Only listens when launched with `--dev-control <state file>`. Commands
/// arrive as distributed notifications named `plus.dpa.satz.dev`, with the
/// command as the object: `press`, `release`, `mic`, `discard`, `undo`,
/// `caret:<index>` (as if clicked there), `field` (logs where the focused
/// text field is), `dump`, which writes the card's
/// phase and text to the state file, `picture`, which saves the live
/// card as a PNG next to it, and `film`, which toggles the eye and saves a
/// picture of every step of the animation.
@MainActor
final class DevControl {

    private let session: Session
    private let card: CardController
    private let stateFile: URL
    private var observer: NSObjectProtocol?
    private var delivered: [String] = []
    /// The eye button, from the app's preferences.
    var toggleEye: () -> Void = {}

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
        case "field": Log.note("focused field: \(FocusedField.frame().map { NSStringFromRect($0) } ?? "unknown")")
        case "picture":
            try? card.picture()?.write(to: stateFile.deletingPathExtension().appendingPathExtension("png"))
        case "film": film()
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
