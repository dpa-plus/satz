import AppKit
import SwiftUI

/// The card's text: a real text view, so the user can click anywhere, select
/// and type, and the session can tell where the caret is.
struct CardTextView: NSViewRepresentable {
    let session: Session
    /// Changes with every edit, so SwiftUI asks for the size again.
    let version: Int

    static let inset = NSSize(width: 12, height: 9)

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
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
        // New text at the end stays in view while dictating.
        if session.phase == .listening || session.phase == .paused {
            DispatchQueue.main.async { context.coordinator.textView?.scrollToEndOfDocument(nil) }
        }
    }

    /// As tall as the text needs at the width offered, up to about five
    /// lines, then it scrolls. Measured from the text itself rather than read
    /// back from the view, which lagged a line behind and cut text off.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? CardView.width
        // The inset on both sides, plus the text container's own padding.
        let available = max(1, width - 2 * (Self.inset.width + 5))
        let bounds = session.text.boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = ceil(bounds.height) + Self.inset.height * 2
        return CGSize(width: width, height: min(max(height, 36), CardView.maxTextHeight))
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let layout = coordinator.textView?.layoutManager {
            coordinator.session.text.removeLayoutManager(layout)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: Session
        weak var textView: NSTextView?

        init(session: Session) {
            self.session = session
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Typed text is plain, even right after a placeholder whose
            // attributes the text view would otherwise carry on.
            textView.typingAttributes = Session.textAttributes
            return session.userWillEdit(range)
        }

        func textDidChange(_ notification: Notification) {
            session.userDidEdit()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !session.isEditing else { return }
            // Typed text is plain: never part of a recording, never a placeholder.
            textView.typingAttributes = Session.textAttributes
            let selection = textView.selectedRange()
            guard selection.length == 0, textView.window?.isKeyWindow == true else { return }
            // Only the user's own moves count. Text arriving moves the caret
            // as well, and taking that for a click put the next recording in
            // the middle of the last one.
            let event = NSApp.currentEvent?.type
            let clicked = [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event)
            guard clicked || event == .keyDown else { return }
            // A click moves where speech goes; typing and arrow keys only
            // decide where to go on after a pause, since splitting the
            // recording at every keystroke would cut it into slivers.
            session.userMovedCaret(to: selection.location, byClick: clicked)
        }
    }
}
