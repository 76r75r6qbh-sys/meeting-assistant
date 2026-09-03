import XCTest
@testable import Casablanca

/// Covers the store primitives that make segment-file collisions and the
/// deletion of recoverable audio impossible. Every test works against real
/// files in a per-test temp directory.
///
/// Named `…SafetyTests` because `RecordingResumeSessionStoreTests` is already
/// taken by the manifest round-trip suite in `PermissionsBehaviorTests.swift`.
final class RecordingResumeSessionStoreSafetyTests: XCTestCase {
    private var rootURL: URL!
    private var store: RecordingResumeSessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingResumeSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let root = rootURL!
        store = RecordingResumeSessionStore(baseDirectoryProvider: { root })
    }

    override func tearDownWithError() throws {
        if let rootURL, FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - reserveNextSegmentURL

    func testReserveNextSegmentURLSkipsNumbersWithExistingWavOrPCM() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        // Segment 1 only left raw PCM behind (a crashed segment), segment 2
        // produced a WAV. Neither may be overwritten.
        try write(bytes: 1_024, to: "segment-001.mic.pcm", for: meetingID)
        try write(bytes: 2_048, to: "segment-002.wav", for: meetingID)

        let reserved = try store.reserveNextSegmentURL(for: meetingID)

        XCTAssertEqual(reserved.lastPathComponent, "segment-003.wav")
        XCTAssertEqual(reserved.deletingLastPathComponent().path, try store.sessionDirectory(for: meetingID).path)
        let session = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(session.nextSegmentNumber, 3)
    }

    func testReserveNextSegmentURLUsesManifestNextSegmentNumberWhenFree() throws {
        let meetingID = UUID()
        try writeManifest(for: meetingID, nextSegmentNumber: 2)

        let reserved = try store.reserveNextSegmentURL(for: meetingID)

        XCTAssertEqual(reserved.lastPathComponent, "segment-002.wav")
        let session = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(session.nextSegmentNumber, 2)
    }

    func testReserveNextSegmentURLSkipsSystemPCMLeftovers() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 512, to: "segment-001.system.pcm", for: meetingID)

        let reserved = try store.reserveNextSegmentURL(for: meetingID)

        XCTAssertEqual(reserved.lastPathComponent, "segment-002.wav")
    }

    // MARK: - appendSegment

    func testAppendSegmentDerivesIndexFromFilename() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: false, selectedInputDeviceID: nil)
        let segmentURL = try store.nextSegmentURL(for: meetingID, segmentNumber: 7)
        try write(bytes: 2_048, to: segmentURL.lastPathComponent, for: meetingID)

        let session = try store.appendSegment(for: meetingID, segmentURL: segmentURL, duration: 12)

        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.segments[0].index, 7)
        XCTAssertEqual(session.segments[0].filePath, segmentURL.path)
        XCTAssertEqual(session.nextSegmentNumber, 8)
        XCTAssertEqual(try XCTUnwrap(store.loadSession(for: meetingID)).nextSegmentNumber, 8)
    }

    func testAppendSegmentFallsBackToCounterForUnrecognizedFilename() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: false, selectedInputDeviceID: nil)
        let segmentURL = try store.sessionDirectory(for: meetingID).appendingPathComponent("recovered-audio.wav")
        try write(bytes: 2_048, to: segmentURL.lastPathComponent, for: meetingID)

        let session = try store.appendSegment(for: meetingID, segmentURL: segmentURL, duration: 3)

        XCTAssertEqual(session.segments[0].index, 1)
        XCTAssertEqual(session.nextSegmentNumber, 2)
    }

    // MARK: - sessionFiles

    func testSessionFilesListsEverythingExceptManifest() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 2_048, to: "segment-001.wav", for: meetingID)
        try write(bytes: 1_024, to: "segment-002.mic.pcm", for: meetingID)
        try write(bytes: 1_024, to: "segment-002.system.pcm", for: meetingID)

        let names = try store.sessionFiles(for: meetingID).map { $0.lastPathComponent }.sorted()

        XCTAssertEqual(names, ["segment-001.wav", "segment-002.mic.pcm", "segment-002.system.pcm"])
        XCTAssertFalse(names.contains("session.json"))
    }

    func testSessionFilesIsEmptyWhenDirectoryIsMissing() throws {
        XCTAssertTrue(try store.sessionFiles(for: UUID()).isEmpty)
    }

    // MARK: - deleteSessionIfEmpty

    func testDeleteSessionIfEmptyKeepsDirectoryWithRecoverableAudio() throws {
        // A non-empty raw PCM file is unmerged audio: never delete it.
        let pcmMeetingID = UUID()
        try store.createSession(for: pcmMeetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 1, to: "segment-001.mic.pcm", for: pcmMeetingID)

        XCTAssertTrue(store.hasRecoverableAudio(for: pcmMeetingID))
        XCTAssertFalse(try store.deleteSessionIfEmpty(for: pcmMeetingID))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try store.sessionDirectory(for: pcmMeetingID).path),
            "directory with unmerged PCM must be kept"
        )

        // A WAV larger than its 44-byte header carries samples: never delete it.
        let wavMeetingID = UUID()
        try store.createSession(for: wavMeetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 45, to: "segment-001.wav", for: wavMeetingID)

        XCTAssertTrue(store.hasRecoverableAudio(for: wavMeetingID))
        XCTAssertFalse(try store.deleteSessionIfEmpty(for: wavMeetingID))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try store.sessionDirectory(for: wavMeetingID).path),
            "directory with a non-empty WAV must be kept"
        )
    }

    func testDeleteSessionIfEmptyRemovesManifestOnlyDirectory() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)

        XCTAssertFalse(store.hasRecoverableAudio(for: meetingID))
        XCTAssertTrue(try store.deleteSessionIfEmpty(for: meetingID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.sessionDirectory(for: meetingID).path))
    }

    func testDeleteSessionIfEmptyRemovesDirectoryWithEmptyPCMAndHeaderOnlyWav() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 0, to: "segment-001.mic.pcm", for: meetingID)
        try write(bytes: 44, to: "segment-001.wav", for: meetingID)

        XCTAssertFalse(store.hasRecoverableAudio(for: meetingID))
        XCTAssertTrue(try store.deleteSessionIfEmpty(for: meetingID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.sessionDirectory(for: meetingID).path))
    }

    // MARK: - Helpers

    private func write(bytes count: Int, to fileName: String, for meetingID: UUID) throws {
        let directory = try store.sessionDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: count).write(to: directory.appendingPathComponent(fileName))
    }

    private func writeManifest(for meetingID: UUID, nextSegmentNumber: Int) throws {
        let now = Date()
        let session = PersistedRecordingSession(
            meetingID: meetingID,
            createdAt: now,
            updatedAt: now,
            nextSegmentNumber: nextSegmentNumber,
            systemAudioEnabled: true,
            selectedInputDeviceID: nil,
            segments: []
        )
        let directory = try store.sessionDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: directory.appendingPathComponent("session.json"))
    }
}
