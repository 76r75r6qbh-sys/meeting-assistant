import AVFoundation
import XCTest
@testable import Casablanca

final class PermissionsBehaviorTests: XCTestCase {
    func testScreenCapturePermissionStateSkipsRequestWhenAlreadyGranted() {
        var requestCallCount = 0

        let state = ScreenCapturePermissionState.resolve(
            preflight: { true },
            request: {
                requestCallCount += 1
                return true
            }
        )

        XCTAssertEqual(state, .granted)
        XCTAssertEqual(requestCallCount, 0)
    }

    func testScreenCapturePermissionStateRequiresRestartAfterFreshGrant() {
        let state = ScreenCapturePermissionState.resolve(
            preflight: { false },
            request: { true }
        )

        XCTAssertEqual(state, .grantedRequiresRestart)
    }

    func testScreenCapturePermissionStateReportsDeniedWhenRequestFails() {
        let state = ScreenCapturePermissionState.resolve(
            preflight: { false },
            request: { false }
        )

        XCTAssertEqual(state, .denied)
    }
}

final class TemporaryRecordingPCMStorageTests: XCTestCase {
    func testRawPCMStorageRoundTripsFloatSamples() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        buffer.floatChannelData!.pointee[0] = -0.25
        buffer.floatChannelData!.pointee[1] = 0.0
        buffer.floatChannelData!.pointee[2] = 0.5
        buffer.floatChannelData!.pointee[3] = 1.0

        let data = TemporaryRecordingPCMStorage.data(from: buffer)
        let samples = TemporaryRecordingPCMStorage.samples(from: data)

        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], -0.25, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[3], 1.0, accuracy: 0.0001)
    }
}

final class RecordingResumeSessionStoreTests: XCTestCase {
    func testLoadSessionWithoutManifestDoesNotCreateMeetingFolder() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meetingID = UUID()
        let sessionDirectory = rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)

        XCTAssertNil(try store.loadSession(for: meetingID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    func testSessionStoreRoundTripsManifestAndSegments() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meetingID = UUID()
        let segmentURL = try store.nextSegmentURL(for: meetingID, segmentNumber: 1)

        _ = try store.createSession(
            for: meetingID,
            systemAudioEnabled: true,
            selectedInputDeviceID: "BuiltInMic"
        )

        let updated = try store.appendSegment(
            for: meetingID,
            segmentURL: segmentURL,
            duration: 12.5
        )

        let reloaded = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(updated, reloaded)
        XCTAssertEqual(reloaded.nextSegmentNumber, 2)
        XCTAssertEqual(reloaded.segments.count, 1)
        XCTAssertEqual(reloaded.segments[0].filePath, segmentURL.path)
    }

    func testAppendSegmentWithoutExistingManifestFailsExplicitly() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meetingID = UUID()
        let segmentURL = rootURL
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent("segment-001.wav")

        XCTAssertThrowsError(
            try store.appendSegment(
                for: meetingID,
                segmentURL: segmentURL,
                duration: 12.5
            )
        ) { error in
            XCTAssertEqual(error as? RecordingResumeSessionStoreError, .sessionNotFound(meetingID))
        }
    }

    func testDeleteSessionRemovesMeetingFolder() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meetingID = UUID()

        _ = try store.createSession(for: meetingID, systemAudioEnabled: false, selectedInputDeviceID: nil)
        let sessionDirectory = try store.sessionDirectory(for: meetingID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))

        try store.deleteSession(for: meetingID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }
}
