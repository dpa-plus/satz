import Observation
import ServiceManagement

/// Whether satz starts when the user logs in. A menu bar tool that is not
/// running does nothing, and people forget they quit it.
///
/// Read from the system rather than stored: the user can switch it off in
/// System Settings > General > Login Items behind the app's back.
@MainActor
@Observable
final class LaunchAtLogin {

    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var problem: String?

    /// Read again: changed in Login Items, or approved there, it was stale.
    func refresh() {
        let now = SMAppService.mainApp.status == .enabled
        if now != isEnabled { isEnabled = now }
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            // Most often: the app is not in /Applications, or macOS wants the
            // user to approve it in Login Items first.
            problem = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
