import AppKit
import AVFoundation
import Observation
import SatzKit

/// The three things satz needs before it can work, and whether each is in place.
///
/// Read from the system rather than remembered, because every one of them can
/// change behind the app's back: the user can revoke a permission in System
/// Settings, or delete the key from Keychain Access, at any moment.
@MainActor
@Observable
final class Setup {

    enum Microphone: Equatable {
        case allowed
        case denied
        case notAsked
    }

    private(set) var hasKey: Bool
    private(set) var microphone: Microphone
    private(set) var canPaste: Bool

    var isComplete: Bool { hasKey && microphone == .allowed && canPaste }

    /// Fixed values, for rendering the settings window without touching the system.
    init(hasKey: Bool, microphone: Microphone, canPaste: Bool) {
        self.hasKey = hasKey
        self.microphone = microphone
        self.canPaste = canPaste
    }

    /// The state of this Mac right now.
    static func current() -> Setup {
        let setup = Setup(hasKey: false, microphone: .notAsked, canPaste: false)
        setup.refresh()
        return setup
    }

    /// Cheap enough to call every second while the window is open. None of these
    /// reads can raise a prompt: the key is checked by its attributes only.
    func refresh() {
        hasKey = Secrets.exists()
        microphone = Self.microphoneStatus()
        canPaste = AXIsProcessTrusted()
    }

    // MARK: - Fixing things

    func store(key: String) throws {
        try Secrets.store(key)
        refresh()
    }

    func removeKey() {
        Secrets.remove()
        refresh()
    }

    func requestMicrophone() async {
        // macOS asks only once. After a "no", the only way back is System Settings.
        if microphone == .denied {
            open(pane: "Privacy_Microphone")
        } else {
            _ = await AudioRecorder.requestPermission()
        }
        refresh()
    }

    func requestPaste() {
        Paster.requestAccessibility()
        open(pane: "Privacy_Accessibility")
    }

    // MARK: - Private

    private static func microphoneStatus() -> Microphone {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private func open(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
