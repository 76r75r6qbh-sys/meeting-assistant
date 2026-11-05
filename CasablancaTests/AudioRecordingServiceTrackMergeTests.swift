import Foundation
import XCTest
@testable import Casablanca

/// Stop merges the per-source speaker tracks while the session directory (and
/// its kept PCM) still exists, and a track merge that fails never fails Stop.
@MainActor
final class AudioRecordingServiceTrackMergeTests: XCTestCase {
    func testStopMergesTracksBeforeDeletingSession() async throws {
        let root = try makeRoot()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { root })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let segmentURL = try makePausedSession(store: store, meeting: meeting)
        let sessionDirectory = try store.sessionDirectory(for: meeting.id)
        let finalURL = root.appendingPathComponent("final.wav")
        let micTrack = root.appendingPathComponent("final.mic.wav")
        let systemTrack = root.appendingPathComponent("final.system.wav")

        let probe = TrackMergeProbe()
        let service = AudioRecordingService(
            sessionStore: store,
            makeFinalOutputURL: { _ in finalURL },
            mergeSegments: { _, _ in 10 },
            mergeTracks: { segmentWAVs, recordingURL in
                probe.segmentWAVs = segmentWAVs
                probe.recordingURL = recordingURL
                probe.sessionExisted = FileManager.default.fileExists(atPath: sessionDirectory.path)
                return SpeakerTrackFiles(microphone: micTrack, system: systemTrack)
            }
        )

        let result = try await service.stopRecording(for: meeting)

        XCTAssertEqual(probe.sessionExisted, true, "tracks must merge before the session directory is deleted")
        XCTAssertEqual(probe.segmentWAVs.map(\.lastPathComponent), [segmentURL.lastPathComponent])
        XCTAssertEqual(probe.recordingURL, finalURL)
        XCTAssertEqual(result.microphoneTrackURL, micTrack)
        XCTAssertEqual(result.systemTrackURL, systemTrack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    /// Uses the real default merger against a kept track it cannot read.
    func testTrackMergeFailureDoesNotFailStop() async throws {
        let root = try makeRoot()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { root })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let segmentURL = try makePausedSession(store: store, meeting: meeting)
        let keptMic = RecordingFiles.keptTrackURL(
            for: segmentURL.deletingPathExtension().appendingPathExtension("mic").appendingPathExtension("pcm")
        )
        try [Float](repeating: 0.25, count: 4).withUnsafeBufferPointer { Data(buffer: $0) }.write(to: keptMic)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keptMic.path)
        let finalURL = root.appendingPathComponent("final.wav")

        let service = AudioRecordingService(
            sessionStore: store,
            makeFinalOutputURL: { _ in finalURL }
        )

        let result = try await service.stopRecording(for: meeting)

        XCTAssertEqual(result.outputURL, finalURL)
        XCTAssertNil(result.microphoneTrackURL)
        XCTAssertNil(result.systemTrackURL)
        XCTAssertGreaterThan(RecordingFiles.byteCount(of: finalURL) ?? 0, WAVCodec.headerByteCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("final.mic.wav").path))
    }

    // MARK: - Helpers

    /// A per-test temp root, removed (permissions restored first) afterwards.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecordingServiceTrackMergeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            if let enumerator = FileManager.default.enumerator(atPath: root.path) {
                for case let path as String in enumerator {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: root.appendingPathComponent(path).path
                    )
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    /// A paused meeting with one finalized 4-frame segment in its manifest.
    private func makePausedSession(store: RecordingResumeSessionStore, meeting: Meeting) throws -> URL {
        try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let url = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        var data = WAVCodec.header(dataByteCount: 8)
        data.append(Data(repeating: 0x11, count: 8))
        try data.write(to: url)
        try store.appendSegment(for: meeting.id, segmentURL: url, duration: 1)
        return url
    }
}

private final class TrackMergeProbe: @unchecked Sendable {
    var segmentWAVs: [URL] = []
    var recordingURL: URL?
    var sessionExisted: Bool?
}
