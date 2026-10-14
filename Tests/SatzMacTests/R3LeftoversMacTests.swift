import AppKit
import Foundation
import SatzKit
import SwiftUI
import Testing
@testable import SatzMac

// The small leftovers of the third bug hunt (14.10.): the pause pill that cut
// "Pausiert" to "Pau…", and the state file that did not say the microphone was
// lost. No window, no microphone, nothing sent anywhere.

@Suite(.serialized) @MainActor
struct R3LeftoversMacTests {

    private func session(_ phase: Session.Phase, text: String = "", lost: Bool = false) -> (Session, Preferences) {
        let preferences = Preferences(defaults: nil)
        let session = Session(preferences: preferences, history: History(), discarded: Discarded())
        session.stage(phase, text: text, microphoneLost: lost)
        return (session, preferences)
    }

    /// How wide the card is drawn: the pill (or the notice) and the window's margin.
    private func drawnWidth(_ phase: Session.Phase, text: String = "", lost: Bool = false) -> CGFloat {
        let (session, preferences) = session(phase, text: text, lost: lost)
        let renderer = ImageRenderer(content: CardView(session: session, preferences: preferences).environment(\.isSnapshot, true))
        renderer.scale = 1
        return renderer.nsImage?.size.width ?? 0
    }

    @Test func thePausePillHasRoomForItsWordAndTheOtherPillsStayAsTheyWere() {
        let language = Language.current
        defer { Language.current = language }
        for spoken in [Language.german, .english] {
            Language.current = spoken
            let margin = 2 * CardPanel.margin
            // Listening is the pill as it was; a pause is wider by what its word needs.
            #expect(drawnWidth(.listening) == CardView.pillWidth + margin)
            #expect(drawnWidth(.idle) == CardView.pillWidth + margin)
            #expect(drawnWidth(.paused) == CardView.pausedPillWidth + margin)
            // What was drawn is wider, not only the constant: the pill the word was cut in was the listening one.
            #expect(drawnWidth(.paused) > drawnWidth(.listening))
            // With the text above it the card is the full width either way.
            #expect(drawnWidth(.paused, text: "Hallo Welt.") == CardView.width + margin)
        }
    }

    @Test func theStateFileSaysWhenTheMicrophoneIsLost() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-r3-leftovers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        for (lost, phase) in [(true, Session.Phase.paused), (false, .paused), (false, .listening)] {
            let (session, preferences) = session(phase, lost: lost)
            let control = DevControl(session: session, card: CardController(session: session, preferences: preferences), stateFile: file)
            control.dump()
            let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(state["microphoneLost"] as? Bool == lost, "\(phase), lost \(lost): \(state["microphoneLost"] ?? "missing")")
            #expect(state["phase"] as? String == String(describing: phase))
        }
    }
}
