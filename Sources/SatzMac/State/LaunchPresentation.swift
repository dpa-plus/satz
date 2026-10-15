import AppKit
import SatzKit

/// A login start stays in the menu bar; opening the app asks for a window.
enum LaunchPresentation {
    enum Destination: Equatable { case quiet, setup, history }

    static func destination(mode: LaunchMode, event: NSAppleEventDescriptor?, setupComplete: Bool) -> Destination {
        guard mode == .normal else { return .quiet }
        if let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication) {
            let origin = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            if origin == OSType(keyAELaunchedAsLogInItem) || origin == OSType(keyAELaunchedAsServiceItem) {
                return .quiet
            }
        }
        return setupComplete ? .history : .setup
    }
}
