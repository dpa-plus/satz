import Observation
import ServiceManagement
import SatzKit

/// Whether satz starts when the user logs in. A menu bar tool that is not
/// running does nothing, and people forget they quit it.
///
/// Read from the system rather than stored: the user can switch it off in
/// System Settings > General > Login Items behind the app's back.
@MainActor
@Observable
final class LaunchAtLogin {

    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    /// Why a switch-on did not take, for a line under the switch.
    private enum Trouble: Equatable {
        case failed(String)
        /// Registered, but macOS waits for the user's OK in Login Items. No
        /// error is thrown for it: the switch just stays off, with nothing said.
        case needsApproval
    }
    private var trouble: Trouble?

    /// What to tell the user, in the app's language as it is now.
    var problem: String? {
        switch trouble {
        case .failed(let why)?:
            de("Nicht eingeschaltet: \(why)", en: "Not switched on: \(why)")
        case .needsApproval?:
            de("Erst in den Systemeinstellungen zustimmen: Allgemein > Anmeldeobjekte",
               en: "Approve it in System Settings first: General > Login Items")
        case nil:
            nil
        }
    }

    /// Read again: changed in Login Items, or approved there, it was stale.
    func refresh() {
        let status = SMAppService.mainApp.status
        let now = status == .enabled
        if now != isEnabled { isEnabled = now }
        // Approved there, or gone: the line has nothing left to say.
        if trouble == .needsApproval && status != .requiresApproval { trouble = nil }
        if now && trouble != nil { trouble = nil }
    }

    func set(_ enabled: Bool) {
        trouble = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { trouble = .needsApproval }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Most often: the app is not in /Applications.
            trouble = .failed(error.localizedDescription)
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
