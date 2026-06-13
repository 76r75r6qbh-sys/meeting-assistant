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

final class OnboardingCaptureStatusTests: XCTestCase {
    func testWithoutMicrophoneCannotRecordAndWarns() {
        let status = OnboardingCaptureStatus(microphoneGranted: false, screenCaptureGranted: false)

        XCTAssertFalse(status.canRecord)
        XCTAssertFalse(status.isMicrophoneOnly)
        XCTAssertFalse(status.capturesAllParticipants)
        XCTAssertEqual(status.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(status.title, "Microphone needed to record")
    }

    func testMicrophoneOnlyCanRecordButFlagsMissingOtherSide() {
        let status = OnboardingCaptureStatus(microphoneGranted: true, screenCaptureGranted: false)

        XCTAssertTrue(status.canRecord)
        XCTAssertTrue(status.isMicrophoneOnly)
        XCTAssertFalse(status.capturesAllParticipants)
        XCTAssertEqual(status.title, "Microphone-only recording")
        XCTAssertTrue(status.detail.contains("only your own microphone"))
    }

    func testMicrophoneAndScreenCaptureRecordsAllParticipants() {
        let status = OnboardingCaptureStatus(microphoneGranted: true, screenCaptureGranted: true)

        XCTAssertTrue(status.canRecord)
        XCTAssertFalse(status.isMicrophoneOnly)
        XCTAssertTrue(status.capturesAllParticipants)
        XCTAssertEqual(status.symbol, "checkmark.circle.fill")
        XCTAssertEqual(status.title, "Full capture ready")
    }

    func testScreenCaptureWithoutMicrophoneStillCannotRecord() {
        // Screen Recording alone is not sufficient — microphone is the hard gate.
        let status = OnboardingCaptureStatus(microphoneGranted: false, screenCaptureGranted: true)

        XCTAssertFalse(status.canRecord)
        XCTAssertFalse(status.capturesAllParticipants)
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

final class RecordingSegmentMergerTests: XCTestCase {
    func testMergeConcatenatesExistingWavFilesInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("segment-001.wav")
        let second = directory.appendingPathComponent("segment-002.wav")
        let output = directory.appendingPathComponent("final.wav")

        try writeMonoWAV(samples: [0, 1000], to: first)
        try writeMonoWAV(samples: [2000, 3000], to: second)

        let duration = try RecordingSegmentMerger.merge(segmentURLs: [first, second], into: output)

        XCTAssertEqual(duration, 4.0 / 16_000.0, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testMergeWithSingleSegmentProducesEquivalentOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let only = directory.appendingPathComponent("segment-001.wav")
        let output = directory.appendingPathComponent("final.wav")

        try writeMonoWAV(samples: [100, 200, 300], to: only)

        let duration = try RecordingSegmentMerger.merge(segmentURLs: [only], into: output)

        XCTAssertEqual(duration, 3.0 / 16_000.0, accuracy: 0.0001)
        let outputData = try Data(contentsOf: output)
        XCTAssertEqual(outputData.count, 44 + 3 * MemoryLayout<Int16>.size)
    }

    private func writeMonoWAV(samples: [Int16], to url: URL) throws {
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let header = RecordingSegmentMerger.header(dataByteCount: payload.count)
        try (header + payload).write(to: url, options: .atomic)
    }
}
