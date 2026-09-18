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

    /// Whether the selected provider has a key.
    private(set) var hasKey: Bool
    private(set) var microphone: Microphone
    private(set) var canPaste: Bool

    var isComplete: Bool {
        hasKey && microphone == .allowed && canPaste && !(preferences?.isEndpointMissing ?? false)
    }

    /// nil for a fixture, whose values never change.
    private let preferences: Preferences?

    /// Fixed values, for rendering the settings window without touching the system.
    init(hasKey: Bool, microphone: Microphone, canPaste: Bool) {
        self.hasKey = hasKey
        self.microphone = microphone
        self.canPaste = canPaste
        preferences = nil
    }

    /// The state of this Mac right now, for the provider `preferences` selects.
    init(preferences: Preferences) {
        self.preferences = preferences
        hasKey = false
        microphone = .notAsked
        canPaste = false
        refresh()
    }

    /// Cheap enough to call every second while the window is open. None of these
    /// reads can raise a prompt: the key is checked by its attributes only.
    func refresh() {
        guard let preferences else { return }
        hasKey = Secrets.exists(for: preferences.provider)
        microphone = Self.microphoneStatus()
        canPaste = AXIsProcessTrusted()
    }

    // MARK: - Fixing things

    func store(key: String) throws {
        guard let preferences else { return }
        try Secrets.store(key, for: preferences.provider)
        refresh()
    }

    func removeKey() {
        guard let preferences else { return }
        Secrets.remove(for: preferences.provider)
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
