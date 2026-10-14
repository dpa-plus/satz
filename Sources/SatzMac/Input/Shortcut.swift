import AppKit
import Observation

/// Keeps the chosen trigger armed.
///
/// Picks the mechanism the trigger needs, re-arms when the user picks another,
/// and waits for Accessibility when the trigger needs it: granting it happens
/// in System Settings, which gives the app no signal, so it checks again every
/// couple of seconds until it can.
@MainActor
@Observable
final class Shortcut {

    enum Status: Equatable {
        case armed
        /// The trigger watches raw events and Accessibility is not granted yet.
        case needsAccessibility
        /// Another app registered the same key combination first.
        case taken
        /// macOS itself uses it (Spotlight and the like), and wins.
        case takenByMacOS
    }

    private(set) var status: Status = .needsAccessibility

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let onPress: () -> Void
    @ObservationIgnored private let onRelease: () -> Void
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var monitor: TriggerMonitor?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    /// The settings window is recording a replacement. Nothing may arm the old
    /// trigger until `resume`: not the waiter for Accessibility, not a change
    /// of the preference.
    @ObservationIgnored private var paused = false
    /// What the checks need from the system. Tests replace them: the real ones
    /// want the permission and an event tap.
    @ObservationIgnored var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    @ObservationIgnored var makeMonitor: (Trigger, @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> TriggerMonitor? = {
        TriggerMonitor(trigger: $0, onPress: $1, onRelease: $2)
    }
    @ObservationIgnored var recheckInterval: Duration = .seconds(2)
    /// The test copy never starts it; recording a trigger in its settings
    /// must not arm one there either.
    @ObservationIgnored private var started = false

    init(preferences: Preferences, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.preferences = preferences
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Arms the current trigger, and re-arms whenever it changes.
    func start() {
        started = true
        arm()
        watchForChanges()
    }

    /// Disarms without forgetting, while the settings window records a new
    /// trigger: pressing the old one there must not start a dictation.
    func pause() {
        paused = true
        hotKey = nil
        monitor = nil
        waiting?.cancel()
        waiting = nil
    }

    func resume() {
        paused = false
        guard started else { return }
        arm()
    }

    // MARK: - Private

    private func arm() {
        guard !paused else { return }
        hotKey = nil
        monitor = nil
        waiting?.cancel()

        let trigger = preferences.trigger
        switch trigger {
        case .keys(let keyCode, let modifiers):
            do {
                let combination = HotKey.Combination(keyCode: keyCode, modifiers: modifiers)
                hotKey = try HotKey(
                    combination,
                    onPress: { [weak self] in self?.onPress() },
                    onRelease: { [weak self] in self?.onRelease() }
                )
                // Registered either way, in case macOS's own use is switched
                // off later; said, because until then nothing happens.
                status = HotKey.isUsedByMacOS(combination) ? .takenByMacOS : .armed
            } catch {
                status = .taken
            }
        case .doubleRightCommand, .mouseButton:
            monitor = makeMonitor(
                trigger,
                { [weak self] in self?.onPress() },
                { [weak self] in self?.onRelease() }
            )
            if monitor != nil {
                status = .armed
            } else {
                status = .needsAccessibility
                waitForAccessibility()
            }
        }
        Log.note("shortcut \(status)")
    }

    private func waitForAccessibility() {
        let interval = recheckInterval, isTrusted = isTrusted
        waiting = Task { [weak self] in
            while !Task.isCancelled {
                // A cancelled sleep ends the wait. Carrying on after it armed
                // the old trigger while the settings window was recording a
                // replacement, once the permission had come in.
                do { try await Task.sleep(for: interval) } catch { return }
                if !Task.isCancelled, isTrusted() {
                    self?.arm()
                    return
                }
            }
        }
    }

    private func watchForChanges() {
        withObservationTracking {
            _ = preferences.trigger
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.arm()
                self?.watchForChanges()
            }
        }
    }
}
