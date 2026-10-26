import CoreAudio
import Foundation

/// A microphone macOS knows about.
struct InputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    /// Stable across restarts and reconnects, unlike `id`. What gets saved.
    let uid: String
    let name: String
}

/// The Mac's microphones, read from Core Audio.
enum InputDevices {

    static func all() -> [InputDevice] {
        all(using: CoreAudioInputDeviceProperties())
    }

    private static func all(using hardware: any InputDeviceProperties) -> [InputDevice] {
        hardware.deviceIDs().compactMap { id in
            guard hardware.hasInput(id), let uid = hardware.string(id, kAudioDevicePropertyDeviceUID),
                  let name = hardware.string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Whatever macOS currently uses for input.
    static func systemDefault() -> InputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return all().first { $0.id == id }
    }

    /// The device to record from for a saved UID. nil means "follow macOS",
    /// and so does a UID whose device is not connected right now: recording
    /// from the built-in microphone beats refusing to record at all.
    static func id(forUID uid: String?, using hardware: any InputDeviceProperties = CoreAudioInputDeviceProperties()) -> UInt32? {
        // Resolve again on every start: reconnecting can give the same UID a
        // different ID. Asking Core Audio directly avoids reading every
        // device's streams, UID and name on the shortcut's startup path.
        guard let uid, let id = hardware.deviceID(forUID: uid),
              id != kAudioObjectUnknown, hardware.hasInput(id) else { return nil }
        return id
    }
}

/// The Core Audio boundary, so lookup tests never open a real microphone.
protocol InputDeviceProperties {
    func deviceIDs() -> [AudioDeviceID]
    func hasInput(_ id: AudioDeviceID) -> Bool
    func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String?
    func deviceID(forUID uid: String) -> AudioDeviceID?
}

struct CoreAudioInputDeviceProperties: InputDeviceProperties {

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id
            )
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
