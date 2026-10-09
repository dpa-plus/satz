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

    /// Whether the selected provider has a key; for "Lokal", whether its
    /// model is on this Mac.
    private(set) var hasKey: Bool
    private(set) var microphone: Microphone
    private(set) var canPaste: Bool

    /// Pasting is optional only for a key combination: right ⌘ twice and the
    /// mouse button need the same Accessibility permission to work at all.
    var isComplete: Bool {
        let pasteNeeded = preferences?.trigger.needsEventTap ?? true
        return hasKey && microphone == .allowed && (canPaste || !pasteNeeded)
            && !(preferences?.isEndpointMissing ?? false) && !(preferences?.isModelMissing ?? false)
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
        // Assigned only on change: every assignment re-renders whatever
        // observes it, and this runs every few seconds.
        let key = preferences.provider.needsKey ? Secrets.exists(for: preferences.provider)
            : LocalModels.shared.isInstalled(preferences.model, language: preferences.spokenLanguage)
        let mic = Self.microphoneStatus()
        let paste = AXIsProcessTrusted()
        if key != hasKey { hasKey = key }
        if mic != microphone { microphone = mic }
        if paste != canPaste { canPaste = paste }
    }

    // MARK: - Fixing things

    /// For the provider in use, or for `provider`, one Settings shows without using it.
    func store(key: String, for provider: Provider? = nil) throws {
        guard let preferences else { return }
        try Secrets.store(key, for: provider ?? preferences.provider)
        refresh()
    }

    /// Whether `provider` has a key, in use or not. A fixture has one for each.
    func hasKey(for provider: Provider) -> Bool {
        preferences == nil ? hasKey : Secrets.exists(for: provider)
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
