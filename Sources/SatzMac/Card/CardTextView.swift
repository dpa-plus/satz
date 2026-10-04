import AppKit
import SwiftUI

/// The card's text: a real text view, so the user can click anywhere, select
/// and type, and the session can tell where the caret is.
struct CardTextView: NSViewRepresentable {
    let session: Session
    /// The height the text needs, reported back for the card to size itself.
    @Binding var height: CGFloat

    static let inset = NSSize(width: 12, height: 9)

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, height: $height)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSLayoutManager()
        session.text.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = Self.inset
        textView.insertionPointColor = NSColor(Theme.dark.signal)
        textView.typingAttributes = Session.textAttributes
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Theme.dark.ink).withAlphaComponent(0.18)]

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Read so SwiftUI calls this again whenever satz changes the text.
        _ = session.textVersion
        context.coordinator.remeasure()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let layout = coordinator.textView?.layoutManager {
            coordinator.session.text.removeLayoutManager(layout)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: Session
        let height: Binding<CGFloat>
        weak var textView: NSTextView?

        init(session: Session, height: Binding<CGFloat>) {
            self.session = session
            self.height = height
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Typed text is plain, even right after a placeholder whose
            // attributes the text view would otherwise carry on.
            textView.typingAttributes = Session.textAttributes
            return session.userWillEdit(range)
        }

        func textDidChange(_ notification: Notification) {
            session.userDidEdit()
            remeasure()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !session.isEditing else { return }
            // Typed text is plain: never part of a recording, never a placeholder.
            textView.typingAttributes = Session.textAttributes
            let selection = textView.selectedRange()
            guard selection.length == 0, textView.window?.isKeyWindow == true else { return }
            // Only a click moves where speech goes. Typing and the arrow keys
            // move the caret too, and splitting the recording at every
            // keystroke would cut it into useless slivers.
            let clicked = [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(NSApp.currentEvent?.type)
            session.userMovedCaret(to: selection.location, byClick: clicked)
        }

        func remeasure() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let needed = ceil(used + CardTextView.inset.height * 2)
            if abs(height.wrappedValue - needed) > 0.5 {
                DispatchQueue.main.async { self.height.wrappedValue = needed }
            }
            // New text at the end stays in view.
            if let end = textView.textStorage?.length, textView.selectedRange().location >= end - 1 || session.phase == .listening {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
}
