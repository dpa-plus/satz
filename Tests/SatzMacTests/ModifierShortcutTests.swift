import AppKit
import Carbon.HIToolbox
import Testing
@testable import SatzMac

@Suite(.serialized) @MainActor
struct ModifierShortcutTests {
    @Test func optionCommandCanBeRecordedWithoutAnotherKey() {
        let recorder = TriggerRecorder()
        var captured: Trigger?
        recorder.record(.keys) { captured = $0 }
        defer { recorder.stop() }

        _ = recorder.handle(flags(.option, key: kVK_Option), kind: .keys)
        _ = recorder.handle(flags([.option, .command], key: kVK_Command), kind: .keys)
        #expect(captured == nil)
        _ = recorder.handle(flags(.option, key: kVK_Command), kind: .keys)

        #expect(captured?.display.keys.map(\.glyph) == ["⌥", "⌘"])
        #expect(captured?.needsEventTap == true)

        let suite = "satz.modifier-shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.trigger = captured!
        #expect(Preferences(defaults: defaults).trigger == captured)
    }

    @Test func aRegularKeyAfterTheModifiersStaysPartOfTheShortcut() {
        let recorder = TriggerRecorder()
        var captured: [Trigger?] = []
        recorder.record(.keys) { captured.append($0) }
        defer { recorder.stop() }
        _ = recorder.handle(flags(.option, key: kVK_Option), kind: .keys)
        _ = recorder.handle(flags([.option, .command], key: kVK_Command), kind: .keys)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                  modifierFlags: [.option, .command], timestamp: 0,
                                  windowNumber: 0, context: nil, characters: "k",
                                  charactersIgnoringModifiers: "k", isARepeat: false,
                                  keyCode: UInt16(kVK_ANSI_K))!
        _ = recorder.handle(key, kind: .keys)
        _ = recorder.handle(flags(.option, key: kVK_Command), kind: .keys)
        #expect(captured == [.keys(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey))])
    }

    @Test func tappingTheModifiersFiresOnlyWhenAKeyIsReleased() {
        var events: [String] = []
        let monitor = TriggerMonitor(trigger: .modifiers(UInt32(optionKey | cmdKey)), held: .init(),
                                     onPress: { events.append("press") }, onRelease: { events.append("release") })
        _ = monitor.handle(.flagsChanged, cgFlags(.maskAlternate, key: kVK_Option))
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Command))
        #expect(events.isEmpty)
        _ = monitor.handle(.flagsChanged, cgFlags(.maskAlternate, key: kVK_Command))
        _ = monitor.handle(.flagsChanged, cgFlags([], key: kVK_Option))
        #expect(events == ["press", "release"])
    }

    @Test func optionCommandWithALetterDoesNotStartDictation() {
        var presses = 0
        let monitor = TriggerMonitor(trigger: .modifiers(UInt32(optionKey | cmdKey)), held: .init(),
                                     onPress: { presses += 1 }, onRelease: {})
        _ = monitor.handle(.flagsChanged, cgFlags(.maskAlternate, key: kVK_Option))
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Command))
        let key = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_K), keyDown: true)!
        key.flags = [.maskAlternate, .maskCommand]
        #expect(monitor.handle(.keyDown, key) != nil)
        _ = monitor.handle(.flagsChanged, cgFlags(.maskAlternate, key: kVK_Command))
        _ = monitor.handle(.flagsChanged, cgFlags([], key: kVK_Option))
        #expect(presses == 0)
    }

    @Test(arguments: [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown])
    func ordinaryInputBeforeTheShortcutDoesNotBlockTheNextTap(_ type: CGEventType) {
        var presses = 0
        let monitor = TriggerMonitor(trigger: .modifiers(UInt32(optionKey | cmdKey)), held: .init(),
                                     onPress: { presses += 1 }, onRelease: {})
        let event = CGEvent(source: nil)!
        event.type = type
        event.flags = []
        _ = monitor.handle(type, event)
        _ = monitor.handle(.flagsChanged, cgFlags(.maskAlternate, key: kVK_Option))
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Command))
        _ = monitor.handle(.flagsChanged, cgFlags([], key: kVK_Command))
        #expect(presses == 1)
    }

    @Test func anExtraModifierDoesNotBecomeAPartialShortcutOnRelease() {
        var presses = 0
        let monitor = TriggerMonitor(trigger: .modifiers(UInt32(optionKey | cmdKey)), held: .init(),
                                     onPress: { presses += 1 }, onRelease: {})
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Command))
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand, .maskShift], key: kVK_Shift))
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Shift))
        _ = monitor.handle(.flagsChanged, cgFlags([], key: kVK_Command))
        #expect(presses == 0)
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Command))
        _ = monitor.handle(.flagsChanged, cgFlags([], key: kVK_Command))
        #expect(presses == 1)
    }

    @Test func holdingTheModifiersFiresOnPressAndEndsOnTheFirstRelease() {
        var events: [String] = []
        let monitor = TriggerMonitor(trigger: .modifiers(UInt32(optionKey | cmdKey)), mode: .hold,
                                     held: .init(), onPress: { events.append("press") },
                                     onRelease: { events.append("release") })
        _ = monitor.handle(.flagsChanged, cgFlags(.maskAlternate, key: kVK_Option))
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Command))
        #expect(events == ["press"])
        _ = monitor.handle(.flagsChanged, cgFlags(.maskAlternate, key: kVK_Command))
        _ = monitor.handle(.flagsChanged, cgFlags([], key: kVK_Option))
        #expect(events == ["press", "release"])
    }

    @Test func aModifierReleaseMissedWhileTheEventTapWasOffEndsTheHold() {
        var events: [String] = []
        let monitor = TriggerMonitor(trigger: .modifiers(UInt32(optionKey | cmdKey)), mode: .hold,
                                     held: .init(modifiers: { 0 }), onPress: { events.append("press") },
                                     onRelease: { events.append("release") })
        _ = monitor.handle(.flagsChanged, cgFlags([.maskAlternate, .maskCommand], key: kVK_Command))
        _ = monitor.handle(.tapDisabledByTimeout, CGEvent(source: nil)!)
        _ = monitor.handle(.flagsChanged, cgFlags([], key: kVK_Command))
        #expect(events == ["press", "release"])
    }

    @Test func switchingTapToHoldRearmsTheShortcut() async {
        let preferences = Preferences(defaults: nil)
        preferences.trigger = .modifiers(UInt32(optionKey | cmdKey))
        preferences.triggerMode = .tap
        let shortcut = Shortcut(preferences: preferences, onPress: {}, onRelease: {})
        var armings = 0
        var modes: [TriggerMode] = []
        shortcut.makeMonitor = { trigger, mode, press, release in
            armings += 1
            modes.append(mode)
            return TriggerMonitor(trigger: trigger, mode: mode, held: .init(), onPress: press, onRelease: release)
        }
        shortcut.start()
        #expect(armings == 1)
        preferences.triggerMode = .hold
        try? await Task.sleep(for: .milliseconds(100))
        #expect(armings == 2)
        #expect(modes == [.tap, .hold])
        shortcut.pause()
    }

    private func flags(_ flags: NSEvent.ModifierFlags, key: Int) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: 0, context: nil,
                        characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: UInt16(key))!
    }

    private func cgFlags(_ flags: CGEventFlags, key: Int) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
        return event
    }
}
