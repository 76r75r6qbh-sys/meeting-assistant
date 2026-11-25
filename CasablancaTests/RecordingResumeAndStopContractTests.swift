import Foundation
import XCTest
@testable import Casablanca

/// Two contracts the recovery work depends on:
///
/// 1. Stop merges segments in **recorded** order. The manifest array is
///    append-ordered, and recovery appends whatever it renders or adopts *after*
///    the segments already listed — so `segment-001.wav` can end up behind
///    `segment-002.wav` in the array. Merging in array order would splice a
///    recovered meeting's audio out of chronological order. `index` is the
///    authority.
/// 2. Resume and Stop fail with different messages. A paused meeting whose
///    manifest never landed used to tell the user "There is no active recording
///    to stop." when they pressed *Resume* — nonsense, and the exact state
///    launch recovery now repairs.
@MainActor
final class RecordingResumeAndStopContractTests: XCTestCase {
    func testStopMergesSegmentsInIndexOrderNotManifestOrder() async throws {
        let rootURL = try makeTemporaryDirectory()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        try store.createSession(for: meeting.id, systemAudioEnabled: false, selectedInputDeviceID: nil)
        // Appended out of order, exactly as recovery leaves a repaired session.
        for segmentNumber in [2, 1] {
            let url = try store.nextSegmentURL(for: meeting.id, segmentNumber: segmentNumber)
            try Data(repeating: 0x41, count: 2_048).write(to: url)
            try store.appendSegment(for: meeting.id, segmentURL: url, duration: 5)
        }
        XCTAssertEqual(
            try XCTUnwrap(store.loadSession(for: meeting.id)).segments.map(\.index),
            [2, 1],
            "precondition: the manifest array is out of order"
        )

        let merged = MergedURLBox()
        let service = AudioRecordingService(
            sessionStore: store,
            makeFinalOutputURL: { _ in rootURL.appendingPathComponent("final.wav") },
            mergeSegments: { urls, _ in
                merged.urls = urls
                return 10
            }
        )

        _ = try await service.stopRecording(for: meeting)

        XCTAssertEqual(
            merged.urls.map(\.lastPathComponent),
            ["segment-001.wav", "segment-002.wav"],
            "segments must be merged in recorded order, taken from `index`"
        )
    }

    func testResumeWithoutASessionFailsWithAResumeSpecificMessage() async throws {
        let rootURL = try makeTemporaryDirectory()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let service = AudioRecordingService(sessionStore: store)

        do {
            try await service.resumeRecording(for: meeting)
            XCTFail("resuming a meeting with no session must throw")
        } catch let error as RecordingError {
            guard case .noResumableSession = error else {
                return XCTFail("expected .noResumableSession, got \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "There is no paused recording to resume.")
        }
    }

    func testStopWithoutASessionStillFailsWithTheStopMessage() async throws {
        let rootURL = try makeTemporaryDirectory()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let service = AudioRecordingService(sessionStore: store)

        do {
            _ = try await service.stopRecording(for: meeting)
            XCTFail("stopping a meeting with no session must throw")
        } catch let error as RecordingError {
            guard case .noActiveRecording = error else {
                return XCTFail("expected .noActiveRecording, got \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "There is no active recording to stop.")
        }
    }

    // MARK: - Helpers

    /// Per-test temp directory, torn down with the test. Built inside each test
    /// rather than in `setUp` so nothing crosses the main-actor boundary.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingResumeAndStopContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// Captures what the injected merge closure was handed. A class so the
/// `@Sendable`-adjacent closure can write to it without capturing `self`.
private final class MergedURLBox: @unchecked Sendable {
    var urls: [URL] = []
}
