import CoreAudio
import Foundation

extension AudioRecordingService {
    static func preferredInputDeviceID(in devices: [AudioInputDevice]) -> String? {
        // Test seam (Phase 1b): this no-arg overload reads the live stored
        // preference (UserDefaults) and the Core Audio system default, then
        // forwards to the injectable overload below. Tests call that overload
        // directly with synthetic values, exercising the selection logic
        // without touching UserDefaults or audio hardware. Behavior is identical.
        preferredInputDeviceID(
            in: devices,
            storedPreference: UserDefaults.standard.string(forKey: AppPreferenceKey.defaultRecordingInputDeviceID)
                ?? AppPreferenceValue.systemDefaultRecordingInputDevice,
            defaultDeviceIDProvider: { defaultInputDeviceID() }
        )
    }

    static func preferredInputDeviceID(
        in devices: [AudioInputDevice],
        storedPreference: String,
        defaultDeviceIDProvider: () -> AudioDeviceID?
    ) -> String? {
        if storedPreference == AppPreferenceValue.systemDefaultRecordingInputDevice {
            guard let defaultDeviceID = defaultDeviceIDProvider() else {
                return nil
            }

            return devices.first(where: { $0.deviceID == defaultDeviceID })?.id
        }

        return resolveInputDevice(storedPreference, in: devices)?.id
    }

    /// Finds the device a persisted ID (preference or resume manifest) refers
    /// to. IDs are CoreAudio device UIDs, which survive a reconnect or a
    /// reboot; builds before that stored the numeric `AudioDeviceID`, which
    /// does not. Such a legacy ID is matched numerically as a best effort and
    /// otherwise resolves to `nil` -- the caller then records from the system
    /// default rather than failing or pausing over a number that went stale.
    static func resolveInputDevice(_ storedID: String?, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        guard let storedID, !storedID.isEmpty else { return nil }
        if let device = devices.first(where: { $0.id == storedID }) {
            return device
        }
        guard let legacyDeviceID = AudioDeviceID(storedID) else { return nil }
        return devices.first(where: { $0.deviceID == legacyDeviceID })
    }

    /// The device ID to arm device-loss detection with for a segment recorded
    /// from `storedID`. When that no longer resolves, the segment records from
    /// the system default, so that is what must be watched: arming with the
    /// stale ID made the very next device-list change (any USB plug, any
    /// Bluetooth headset waking up) read as "your mic is gone" and hard-pause
    /// a perfectly healthy recording.
    static func monitoredInputDeviceID(
        forStoredID storedID: String?,
        in devices: [AudioInputDevice],
        defaultDeviceID: AudioDeviceID?,
        fallback: String
    ) -> String {
        if let device = resolveInputDevice(storedID, in: devices) {
            return device.id
        }
        if let defaultDeviceID, let device = devices.first(where: { $0.deviceID == defaultDeviceID }) {
            return device.id
        }
        return fallback
    }

    static func fetchInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size) == noErr else {
            return []
        }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasInputChannels(deviceID),
                  let name = deviceName(deviceID)
            else {
                return nil
            }

            // The UID is the persisted identity: an `AudioDeviceID` is handed
            // out per connection and changes across a reconnect or a reboot.
            return AudioInputDevice(
                id: deviceUID(deviceID) ?? String(deviceID),
                name: name,
                deviceID: deviceID
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    /// `kAudioDevicePropertyDeviceUID`: stable across reconnects and reboots.
    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &name) { namePointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &size,
                namePointer
            )
        }

        guard status == noErr, let name else {
            return nil
        }

        return name as String
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size) == noErr else {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            bufferListPointer
        ) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.contains { $0.mNumberChannels > 0 }
    }
}
