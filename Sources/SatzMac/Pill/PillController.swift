import AppKit
import SwiftUI

/// Owns the pill window and keeps it sized to whatever it is showing.
@MainActor
final class PillController {
    let recording = Recording()

    private var panel: PillPanel?
    private let onCancel: () -> Void
    private let onRetry: () -> Void

    init(onCancel: @escaping () -> Void, onRetry: @escaping () -> Void) {
        self.onCancel = onCancel
        self.onRetry = onRetry
    }

    func show() {
        let panel = panel ?? make()
        self.panel = panel
        panel.present()
    }

    /// The pill changes width between a waveform, a status line and an error,
    /// so the window has to be re-measured whenever the content changes.
    func resize() {
        panel?.reposition()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func make() -> PillPanel {
        let view = PillView(recording: recording, onCancel: onCancel, onRetry: onRetry)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        return PillPanel(content: hosting)
    }
}
