import AppKit
import SatzKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var pill: PillController?
    private var recorder: AudioRecorder?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           let path = CommandLine.arguments[safe: index + 1] {
            try? SnapshotRenderer.write(to: path)
            NSApp.terminate(nil)
            return
        }

        pill = PillController(onCancel: { [weak self] in self?.cancel() })
        installStatusItem()
        installHotKey()

        if CommandLine.arguments.contains("--demo"), let pill {
            pill.show()
            DemoDriver.run(on: pill.recording)
        }
    }

    // MARK: - Shortcut

    private func installHotKey() {
        do {
            hotKey = try HotKey(.optionSpace) { [weak self] in
                Task { await self?.toggleRecording() }
            }
            statusItem?.button?.toolTip = "satz  \u{00B7}  " + HotKey.Combination.optionSpace.display
            Log.note("shortcut registered: \(HotKey.Combination.optionSpace.display)")
        } catch {
            // Surfaced rather than swallowed: without the shortcut the app still
            // works from the menu bar, but the key the user actually reaches for
            // would silently do nothing.
            statusItem?.button?.toolTip = error.localizedDescription
            Log.note("shortcut NOT registered: \(error.localizedDescription)")
            show(failure: error)
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "satz"
        )
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item
    }

    @objc private func toggle() {
        Task { await toggleRecording() }
    }

    // MARK: - Recording

    private func toggleRecording() async {
        if recorder == nil {
            await startRecording()
        } else {
            await finishRecording()
        }
    }

    private func startRecording() async {
        guard let pill else { return }

        let recorder = AudioRecorder()
        recorder.onLevel = { [weak self] level in
            self?.pill?.recording.push(level: level)
        }

        pill.recording.begin()
        pill.show()

        do {
            try await recorder.start()
            self.recorder = recorder
        } catch {
            self.recorder = nil
            show(failure: error)
        }
    }

    private func finishRecording() async {
        guard let recorder, let pill else { return }
        self.recorder = nil

        pill.recording.transcribing()
        pill.resize()

        let audio = await recorder.finish()
        guard audio != nil else {
            dismiss()
            return
        }
        // Step 4 uploads this. Until then, stopping simply clears the pill.
        dismiss()
    }

    private func cancel() {
        recorder?.cancel()
        recorder = nil
        dismiss()
    }

    // MARK: - Pill

    private func show(failure: any Error) {
        guard let pill else { return }
        pill.recording.fail(failure.localizedDescription)
        pill.resize()
        // Leave the message up long enough to read, then clear it. A failure
        // that vanishes instantly is indistinguishable from nothing happening.
        Task {
            try? await Task.sleep(for: .seconds(4))
            self.dismiss()
        }
    }

    private func dismiss() {
        pill?.hide()
        pill?.recording.reset()
    }
}


private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
