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
        hotKey = nil
        monitor = nil
        waiting?.cancel()
    }

    func resume() {
        guard started else { return }
        arm()
    }

    // MARK: - Private

    private func arm() {
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
            monitor = TriggerMonitor(
                trigger: trigger,
                onPress: { [weak self] in self?.onPress() },
                onRelease: { [weak self] in self?.onRelease() }
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
        waiting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if AXIsProcessTrusted() {
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
