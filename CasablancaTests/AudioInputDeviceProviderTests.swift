import CoreAudio
import XCTest
@testable import Casablanca

/// Tests for `AudioRecordingService.preferredInputDeviceID` selection logic
/// (Phase 1b). Phase 1b added an internal overload with injectable
/// `storedPreference` and `defaultDeviceIDProvider` parameters so the selection
/// semantics can be exercised without touching UserDefaults or Core Audio. The
/// public no-arg overload forwards to it with identical behavior.
@MainActor
final class AudioInputDeviceProviderTests: XCTestCase {
    private func device(id: String, deviceID: AudioDeviceID, name: String? = nil) -> AudioInputDevice {
        AudioInputDevice(id: id, name: name ?? "Device \(id)", deviceID: deviceID)
    }

    // MARK: - Explicit stored preference (not "system-default")

    func testPreferredDevicePresentInListIsChosen() {
        let devices = [
            device(id: "10", deviceID: 10),
            device(id: "20", deviceID: 20),
            device(id: "30", deviceID: 30),
        ]
        let result = AudioRecordingService.preferredInputDeviceID(
            in: devices,
            storedPreference: "20",
            defaultDeviceIDProvider: { 99 }
        )
        XCTAssertEqual(result, "20")
    }

    func testPreferredDeviceAbsentFromListReturnsNil() {
        let devices = [
            device(id: "10", deviceID: 10),
            device(id: "20", deviceID: 20),
        ]
        let result = AudioRecordingService.preferredInputDeviceID(
            in: devices,
            storedPreference: "999",
            defaultDeviceIDProvider: { 10 }
        )
        // An explicit stored preference that is no longer present yields nil;
        // it does NOT silently fall back to the system default.
        XCTAssertNil(result)
    }

    // MARK: - "system-default" preference

    func testSystemDefaultResolvesToMatchingDeviceID() {
        let devices = [
            device(id: "10", deviceID: 10),
            device(id: "20", deviceID: 20),
            device(id: "30", deviceID: 30),
        ]
        let result = AudioRecordingService.preferredInputDeviceID(
            in: devices,
            storedPreference: AppPreferenceValue.systemDefaultRecordingInputDevice,
            defaultDeviceIDProvider: { 30 }
        )
        XCTAssertEqual(result, "30")
    }

    func testSystemDefaultWhenDefaultDeviceNotInListReturnsNil() {
        let devices = [
            device(id: "10", deviceID: 10),
            device(id: "20", deviceID: 20),
        ]
        let result = AudioRecordingService.preferredInputDeviceID(
            in: devices,
            storedPreference: AppPreferenceValue.systemDefaultRecordingInputDevice,
            defaultDeviceIDProvider: { 77 }
        )
        XCTAssertNil(result)
    }

    func testSystemDefaultWhenNoDefaultDeviceReturnsNil() {
        let devices = [
            device(id: "10", deviceID: 10),
            device(id: "20", deviceID: 20),
        ]
        let result = AudioRecordingService.preferredInputDeviceID(
            in: devices,
            storedPreference: AppPreferenceValue.systemDefaultRecordingInputDevice,
            defaultDeviceIDProvider: { nil }
        )
        XCTAssertNil(result)
    }

    // MARK: - Empty list

    func testEmptyDeviceListWithExplicitPreferenceReturnsNil() {
        let result = AudioRecordingService.preferredInputDeviceID(
            in: [],
            storedPreference: "10",
            defaultDeviceIDProvider: { 10 }
        )
        XCTAssertNil(result)
    }

    func testEmptyDeviceListWithSystemDefaultReturnsNil() {
        let result = AudioRecordingService.preferredInputDeviceID(
            in: [],
            storedPreference: AppPreferenceValue.systemDefaultRecordingInputDevice,
            defaultDeviceIDProvider: { 10 }
        )
        XCTAssertNil(result)
    }

    // MARK: - Persisted IDs (UIDs, with legacy numeric fallback)

    func testStoredUIDResolvesEvenWhenTheAudioDeviceIDChanged() {
        // Reconnected: same UID, new AudioDeviceID.
        let devices = [
            device(id: "BuiltInMicrophoneDevice", deviceID: 91),
            device(id: "AppleUSBAudioEngine:Jabra:1", deviceID: 140),
        ]
        let resolved = AudioRecordingService.resolveInputDevice("AppleUSBAudioEngine:Jabra:1", in: devices)
        XCTAssertEqual(resolved?.deviceID, 140)
    }

    func testLegacyNumericIDStillResolvesWhileItMatches() {
        let devices = [device(id: "BuiltInMicrophoneDevice", deviceID: 91)]
        XCTAssertEqual(AudioRecordingService.resolveInputDevice("91", in: devices)?.id, "BuiltInMicrophoneDevice")
    }

    func testStaleLegacyNumericIDResolvesToNothing() {
        let devices = [device(id: "BuiltInMicrophoneDevice", deviceID: 91)]
        XCTAssertNil(AudioRecordingService.resolveInputDevice("57", in: devices))
        XCTAssertNil(AudioRecordingService.resolveInputDevice("", in: devices))
        XCTAssertNil(AudioRecordingService.resolveInputDevice(nil, in: devices))
    }

    func testLegacyNumericPreferenceIsHonouredAsTheMatchingUID() {
        let devices = [
            device(id: "BuiltInMicrophoneDevice", deviceID: 91),
            device(id: "AppleUSBAudioEngine:Jabra:1", deviceID: 140),
        ]
        let result = AudioRecordingService.preferredInputDeviceID(
            in: devices,
            storedPreference: "140",
            defaultDeviceIDProvider: { 91 }
        )
        XCTAssertEqual(result, "AppleUSBAudioEngine:Jabra:1")
    }

    /// The segment of a stale ID records from the system default, so device
    /// loss must watch the default -- not the stale ID, which reads as "gone"
    /// on the next device-list change and hard-pauses a healthy recording.
    func testMonitoringFallsBackToTheSystemDefaultForAStaleID() {
        let devices = [
            device(id: "BuiltInMicrophoneDevice", deviceID: 91),
            device(id: "AppleUSBAudioEngine:Jabra:1", deviceID: 140),
        ]
        let monitored = AudioRecordingService.monitoredInputDeviceID(
            forStoredID: "57",
            in: devices,
            defaultDeviceID: 91,
            fallback: "AppleUSBAudioEngine:Jabra:1"
        )
        XCTAssertEqual(monitored, "BuiltInMicrophoneDevice")
    }

    func testMonitoringUsesTheResolvedUID() {
        let devices = [device(id: "AppleUSBAudioEngine:Jabra:1", deviceID: 140)]
        XCTAssertEqual(
            AudioRecordingService.monitoredInputDeviceID(
                forStoredID: "140",
                in: devices,
                defaultDeviceID: nil,
                fallback: "x"
            ),
            "AppleUSBAudioEngine:Jabra:1"
        )
    }

    func testMonitoringWithoutAnyMatchUsesTheFallback() {
        XCTAssertEqual(
            AudioRecordingService.monitoredInputDeviceID(
                forStoredID: "57",
                in: [],
                defaultDeviceID: 91,
                fallback: "current"
            ),
            "current"
        )
    }

    // MARK: - First-match semantics

    func testSystemDefaultPicksFirstMatchingDeviceIDInListOrder() {
        // Two entries share deviceID 10; the first encountered wins (`first(where:)`).
        let devices = [
            device(id: "alpha", deviceID: 10),
            device(id: "beta", deviceID: 10),
        ]
        let result = AudioRecordingService.preferredInputDeviceID(
            in: devices,
            storedPreference: AppPreferenceValue.systemDefaultRecordingInputDevice,
            defaultDeviceIDProvider: { 10 }
        )
        XCTAssertEqual(result, "alpha")
    }
}
