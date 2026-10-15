import AppKit
import SatzKit
import Testing
@testable import SatzMac

@Suite struct LaunchPresentationTests {
    private func launchEvent(marker: AEKeyword? = nil, eventID: AEEventID = AEEventID(kAEOpenApplication), eventClass: AEEventClass = AEEventClass(kCoreEventClass)) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: eventClass, eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        if let marker {
            event.setParam(NSAppleEventDescriptor(enumCode: OSType(marker)), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    @Test func openingAStoppedConfiguredAppShowsHistory() {
        #expect(LaunchPresentation.destination(mode: .normal, event: launchEvent(), setupComplete: true) == .history)
    }

    @Test func aDirectLaunchWithoutAnAppleEventAlsoShowsHistory() {
        #expect(LaunchPresentation.destination(mode: .normal, event: nil, setupComplete: true) == .history)
    }

    @Test func anOrdinaryFirstLaunchShowsSetup() {
        #expect(LaunchPresentation.destination(mode: .normal, event: launchEvent(), setupComplete: false) == .setup)
        #expect(LaunchPresentation.destination(mode: .normal, event: nil, setupComplete: false) == .setup)
    }

    @Test(arguments: [true, false])
    func loginStartsStayQuietEvenWhenSetupIsIncomplete(setupComplete: Bool) {
        let event = launchEvent(marker: AEKeyword(keyAELaunchedAsLogInItem))
        #expect(LaunchPresentation.destination(mode: .normal, event: event, setupComplete: setupComplete) == .quiet)
    }

    @Test(arguments: [true, false])
    func serviceStartsStayQuietEvenWhenSetupIsIncomplete(setupComplete: Bool) {
        let event = launchEvent(marker: AEKeyword(keyAELaunchedAsServiceItem))
        #expect(LaunchPresentation.destination(mode: .normal, event: event, setupComplete: setupComplete) == .quiet)
    }

    @Test func aZeroLaunchMarkerStillMeansAnOrdinaryLaunch() {
        #expect(LaunchPresentation.destination(mode: .normal, event: launchEvent(marker: 0), setupComplete: true) == .history)
    }

    @Test func aLoginMarkerOnAnotherEventDoesNotMakeItALoginLaunch() {
        let event = launchEvent(marker: AEKeyword(keyAELaunchedAsLogInItem), eventID: AEEventID(kAEReopenApplication))
        #expect(LaunchPresentation.destination(mode: .normal, event: event, setupComplete: true) == .history)
    }

    @Test func aLoginMarkerOutsideTheLaunchEventClassDoesNotMakeItALoginLaunch() {
        let event = launchEvent(marker: AEKeyword(keyAELaunchedAsLogInItem), eventClass: AEEventClass(kAECoreSuite))
        #expect(LaunchPresentation.destination(mode: .normal, event: event, setupComplete: true) == .history)
    }

    @Test(arguments: [true, false])
    func testCopiesStayQuietWithoutTouchingWindows(setupComplete: Bool) {
        for event in [nil, launchEvent(), launchEvent(marker: AEKeyword(keyAELaunchedAsLogInItem))] {
            #expect(LaunchPresentation.destination(mode: .test(stateFile: "/tmp/satz-synthetic-state.json", modelsFolder: nil), event: event, setupComplete: setupComplete) == .quiet)
        }
    }

    @Test(arguments: [true, false])
    func invalidLaunchesNeverAskForAWindow(setupComplete: Bool) {
        #expect(LaunchPresentation.destination(mode: .invalid("synthetic invalid flag"), event: launchEvent(), setupComplete: setupComplete) == .quiet)
    }
}
