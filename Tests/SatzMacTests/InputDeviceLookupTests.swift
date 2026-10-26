import CoreAudio
import Testing
@testable import SatzMac

private final class DeviceProperties: InputDeviceProperties {
    var translated: AudioDeviceID? = 42
    var inputAvailable = true
    var lookedUp: [String] = []
    var enumerations = 0
    var checkedInputs: [AudioDeviceID] = []

    func deviceIDs() -> [AudioDeviceID] {
        enumerations += 1
        guard let translated, translated != kAudioObjectUnknown else { return [] }
        return [translated]
    }

    func hasInput(_ id: AudioDeviceID) -> Bool {
        checkedInputs.append(id)
        return inputAvailable
    }

    func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        selector == kAudioDevicePropertyDeviceUID ? "saved-microphone" : "Microphone"
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        lookedUp.append(uid)
        return translated
    }
}

struct InputDeviceLookupTests {
    @Test func aSavedMicrophoneIsResolvedWithoutEnumeratingOtherDevices() {
        let hardware = DeviceProperties()
        #expect(InputDevices.id(forUID: "saved-microphone", using: hardware) == 42)
        #expect(hardware.lookedUp == ["saved-microphone"])
        #expect(hardware.enumerations == 0)
        #expect(hardware.checkedInputs == [42])
    }

    @Test func followingMacOSDoesNotLookUpAnyDevice() {
        let hardware = DeviceProperties()
        #expect(InputDevices.id(forUID: nil, using: hardware) == nil)
        #expect(hardware.lookedUp.isEmpty && hardware.checkedInputs.isEmpty && hardware.enumerations == 0)
    }

    @Test func reconnectingUsesTheNewDeviceIDForTheSameSavedMicrophone() {
        let hardware = DeviceProperties()
        #expect(InputDevices.id(forUID: "saved-microphone", using: hardware) == 42)
        hardware.translated = 87
        #expect(InputDevices.id(forUID: "saved-microphone", using: hardware) == 87)
        #expect(hardware.lookedUp == ["saved-microphone", "saved-microphone"])
    }

    @Test func aMissingOrOutputOnlyDeviceFallsBackToMacOS() {
        let hardware = DeviceProperties()
        hardware.translated = nil
        #expect(InputDevices.id(forUID: "saved-microphone", using: hardware) == nil)
        hardware.translated = kAudioObjectUnknown
        #expect(InputDevices.id(forUID: "saved-microphone", using: hardware) == nil)
        hardware.translated = 42
        hardware.inputAvailable = false
        #expect(InputDevices.id(forUID: "saved-microphone", using: hardware) == nil)
    }
}
