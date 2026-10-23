import AppKit
import Carbon.HIToolbox
import Testing
@testable import SatzMac

// F10 and F11 of the 14.10. bug hunt. No event tap is installed, no
// permission asked and no event posted: the monitor's handler gets events
// built by hand, and what the system "holds down" is a stand-in.

// MARK: - F10: a mouse button's release lost while the tap was off

@MainActor
private final class SystemInput {
    var mouseButtons: Set<Int> = []
    var rightCommand = false
    var asked = 0

    var monitorState: TriggerMonitor.Held {
        TriggerMonitor.Held(
            rightCommand: { MainActor.assumeIsolated { self.rightCommand } },
            mouseButton: { number in MainActor.assumeIsolated { self.asked += 1; return self.mouseButtons.contains(number) } }
        )
    }
}

@MainActor
private final class Heard {
    var events: [String] = []
}

@MainActor
private func monitor(_ trigger: Trigger, held: SystemInput, heard: Heard) -> TriggerMonitor {
    TriggerMonitor(trigger: trigger, held: held.monitorState,
                   onPress: { heard.events.append("press") }, onRelease: { heard.events.append("release") })
}

private func mouse(_ type: CGEventType, button: Int64) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = type
    event.setIntegerValueField(.mouseEventButtonNumber, value: button)
    return event
}

private func modifier(rightCommandDown: Bool) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = .flagsChanged
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_RightCommand))
    event.flags = CGEventFlags(rawValue: rightCommandDown ? 0x10 : 0)
    return event
}

private func tapSwitchedOff(_ type: CGEventType = .tapDisabledByTimeout) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = type
    return event
}

@Suite(.serialized) @MainActor
struct MouseHoldRecoveryTests {

    @Test func aReleaseMissedWhileTheTapWasOffEndsTheHold() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.mouseButton(3), held: held, heard: heard)
        held.mouseButtons = [3]
        _ = monitor.handle(.otherMouseDown, mouse(.otherMouseDown, button: 3))
        // The tap goes off, the finger comes up, the tap comes back.
        held.mouseButtons = []
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        #expect(heard.events == ["press", "release"])
    }

    @Test func theOtherWayOfTheTapGoingOffIsRecoveredToo() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.mouseButton(4), held: held, heard: heard)
        _ = monitor.handle(.otherMouseDown, mouse(.otherMouseDown, button: 4))
        _ = monitor.handle(.tapDisabledByUserInput, tapSwitchedOff(.tapDisabledByUserInput))
        #expect(heard.events == ["press", "release"])
    }

    @Test func aButtonStillHeldIsLeftHeldAndItsRealReleaseStillEndsTheHold() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.mouseButton(3), held: held, heard: heard)
        held.mouseButtons = [3]
        _ = monitor.handle(.otherMouseDown, mouse(.otherMouseDown, button: 3))
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        #expect(heard.events == ["press"])
        held.mouseButtons = []
        _ = monitor.handle(.otherMouseUp, mouse(.otherMouseUp, button: 3))
        #expect(heard.events == ["press", "release"])
    }

    @Test func aHoldThatEndedNormallyIsNotEndedAgain() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.mouseButton(3), held: held, heard: heard)
        _ = monitor.handle(.otherMouseDown, mouse(.otherMouseDown, button: 3))
        _ = monitor.handle(.otherMouseUp, mouse(.otherMouseUp, button: 3))
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        #expect(heard.events == ["press", "release"])
        #expect(held.asked == 0)
    }

    @Test func aButtonNeverSeenGoingDownIsNotReleased() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.mouseButton(3), held: held, heard: heard)
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        #expect(heard.events.isEmpty)
    }

    @Test func anotherButtonIsNotTheTriggersHold() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.mouseButton(3), held: held, heard: heard)
        _ = monitor.handle(.otherMouseDown, mouse(.otherMouseDown, button: 4))
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        #expect(heard.events.isEmpty)
    }

    @Test func aReleasedHoldCanStartAgain() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.mouseButton(3), held: held, heard: heard)
        _ = monitor.handle(.otherMouseDown, mouse(.otherMouseDown, button: 3))
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        held.mouseButtons = [3]
        _ = monitor.handle(.otherMouseDown, mouse(.otherMouseDown, button: 3))
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        #expect(heard.events == ["press", "release", "press"])
        held.mouseButtons = []
        _ = monitor.handle(.otherMouseUp, mouse(.otherMouseUp, button: 3))
        #expect(heard.events == ["press", "release", "press", "release"])
    }

    @Test func theRightCommandHoldStillRecoversToo() {
        let held = SystemInput(), heard = Heard()
        let monitor = monitor(.doubleRightCommand, held: held, heard: heard)
        _ = monitor.handle(.flagsChanged, modifier(rightCommandDown: true))
        _ = monitor.handle(.flagsChanged, modifier(rightCommandDown: false))
        _ = monitor.handle(.flagsChanged, modifier(rightCommandDown: true))
        held.rightCommand = false
        _ = monitor.handle(.tapDisabledByTimeout, tapSwitchedOff())
        #expect(heard.events == ["press", "release"])
    }
}

// MARK: - F11: the waiter for Accessibility against a recording in progress

@MainActor
private final class Permission {
    var granted = false
    var monitorsMade = 0
}

@MainActor
private func shortcut(trigger: Trigger, permission: Permission) -> Shortcut {
    let preferences = Preferences(defaults: nil)
    preferences.trigger = trigger
    let shortcut = Shortcut(preferences: preferences, onPress: {}, onRelease: {})
    shortcut.isTrusted = { permission.granted }
    shortcut.recheckInterval = .milliseconds(50)
    shortcut.makeMonitor = { trigger, mode, press, release in
        guard permission.granted else { return nil }
        permission.monitorsMade += 1
        return TriggerMonitor(trigger: trigger, mode: mode, held: .init(), onPress: press, onRelease: release)
    }
    return shortcut
}

@Suite(.serialized) @MainActor
struct ShortcutRecordingTests {

    @Test func theWaiterDoesNotArmTheOldShortcutWhileAReplacementIsRecorded() async {
        let permission = Permission()
        let shortcut = shortcut(trigger: .doubleRightCommand, permission: permission)
        shortcut.start()
        #expect(shortcut.status == .needsAccessibility)
        // The waiter is asleep; the permission comes in, then recording starts.
        try? await Task.sleep(for: .milliseconds(20))
        permission.granted = true
        shortcut.pause()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(permission.monitorsMade == 0)
        #expect(shortcut.status == .needsAccessibility)

        // Recording over: now it arms.
        shortcut.resume()
        #expect(permission.monitorsMade == 1)
        #expect(shortcut.status == .armed)
    }

    @Test func aTriggerChangedWhileRecordingIsNotArmedUntilTheRecordingEnds() async {
        let permission = Permission()
        permission.granted = true
        let preferences = Preferences(defaults: nil)
        preferences.trigger = .doubleRightCommand
        let shortcut = Shortcut(preferences: preferences, onPress: {}, onRelease: {})
        shortcut.isTrusted = { permission.granted }
        shortcut.makeMonitor = { trigger, mode, press, release in
            permission.monitorsMade += 1
            return TriggerMonitor(trigger: trigger, mode: mode, held: .init(), onPress: press, onRelease: release)
        }
        shortcut.start()
        #expect(permission.monitorsMade == 1)

        shortcut.pause()
        preferences.trigger = .mouseButton(3)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(permission.monitorsMade == 1)

        shortcut.resume()
        #expect(permission.monitorsMade == 2)
    }

    @Test func theWaiterStillArmsOnceThePermissionComesIn() async {
        let permission = Permission()
        let shortcut = shortcut(trigger: .mouseButton(3), permission: permission)
        shortcut.start()
        #expect(shortcut.status == .needsAccessibility)
        permission.granted = true
        var armed = false
        let end = Date().addingTimeInterval(3)
        while !armed, Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
            armed = shortcut.status == .armed
        }
        #expect(armed)
        #expect(permission.monitorsMade == 1)
    }

    @Test func resumingWithoutStartingArmsNothing() async {
        let permission = Permission()
        permission.granted = true
        let shortcut = shortcut(trigger: .doubleRightCommand, permission: permission)
        shortcut.pause()
        shortcut.resume()
        #expect(permission.monitorsMade == 0)
        // The test copy never starts it; a pause and resume must leave it that way.
        #expect(shortcut.status == .needsAccessibility)
    }
}
