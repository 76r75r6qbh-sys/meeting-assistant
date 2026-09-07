import XCTest
@testable import Casablanca

/// Covers the launch-time recovery sweep over
/// `~/Library/Application Support/Casablanca/RecordingSessions`: which
/// orphaned session directories are disposable, which still hold raw PCM that
/// has to be rendered, and which already hold finalized segments. Everything
/// runs against real files in a per-test temp directory — the sweep's whole
/// job is filesystem classification, so faking the filesystem would test
/// nothing.
final class RecordingSessionRecoveryTests: XCTestCase {
    private var rootURL: URL!
    private var store: RecordingResumeSessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionRecoveryTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - scan

    func testScanClassifiesEmptyManifestOnlyDirectoryAsDisposable() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)

        XCTAssertEqual(try RecordingSessionRecovery.scan(store: store), [.disposable(meetingID)])
    }

    func testScanFindsOrphanedPCMPairNotInManifest() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 4_096, to: "segment-001.mic.pcm", for: meetingID)
        try write(bytes: 0, to: "segment-001.system.pcm", for: meetingID)

        XCTAssertEqual(
            try RecordingSessionRecovery.scan(store: store),
            [.orphanedPCM(meetingID, segmentNumbers: [1], strandedPCM: [])]
        )
    }

    func testScanFindsManifestWithFinalizedSegmentButNoMerge() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let segmentURL = try store.nextSegmentURL(for: meetingID, segmentNumber: 1)
        try write(bytes: 2_048, to: segmentURL.lastPathComponent, for: meetingID)
        try store.appendSegment(for: meetingID, segmentURL: segmentURL, duration: 42)

        XCTAssertEqual(
            try RecordingSessionRecovery.scan(store: store),
            [.resumable(meetingID, segmentCount: 1, strandedPCM: [])]
        )
    }

    func testScanIgnoresDirectoriesThatAreNotUUIDs() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        // A stray directory and a stray file next to the session directories.
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("not-a-uuid", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: rootURL.appendingPathComponent(".DS_Store"))

        XCTAssertEqual(try RecordingSessionRecovery.scan(store: store), [.disposable(meetingID)])
    }

    func testScanClassifiesStrayWavWithoutManifestEntryAsResumable() throws {
        // The manifest counter says a segment was reserved but the append
        // never landed. The WAV is real audio: resumable, never disposable.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 2_048, to: "segment-001.wav", for: meetingID)

        XCTAssertEqual(
            try RecordingSessionRecovery.scan(store: store),
            [.resumable(meetingID, segmentCount: 1, strandedPCM: [])]
        )
    }

    // MARK: - renderOrphanedTracks

    func testRecoverRendersOrphanedPCMIntoSegmentAndAppendsManifest() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)
        let micURL = directory.appendingPathComponent("segment-001.mic.pcm")
        let systemURL = directory.appendingPathComponent("segment-001.system.pcm")
        try writeFloatSamples(count: 16_000, to: micURL)
        try Data().write(to: systemURL)

        let rendered = try RecordingSessionRecovery.renderOrphanedTracks(meetingID: meetingID, store: store)

        XCTAssertEqual(rendered, 1)
        let wavURL = directory.appendingPathComponent("segment-001.wav")
        XCTAssertEqual(try fileSize(of: wavURL), 44 + 32_000)

        let session = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.segments[0].index, 1)
        XCTAssertEqual(session.segments[0].filePath, wavURL.path)
        XCTAssertEqual(session.segments[0].duration, 1.0, accuracy: 0.0001)

        // The renderer owns PCM deletion and only on its success path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertEqual(try RecordingSessionRecovery.scan(store: store), [.resumable(meetingID, segmentCount: 1, strandedPCM: [])])
    }

    func testRecoverLeavesOccupiedSegmentsUntouched() throws {
        // segment-001.wav already carries samples: rendering over it would
        // destroy a finished recording, so the PCM must be left untouched too.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)
        let wavURL = directory.appendingPathComponent("segment-001.wav")
        let micURL = directory.appendingPathComponent("segment-001.mic.pcm")
        try Data(repeating: 0x41, count: 4_096).write(to: wavURL)
        try writeFloatSamples(count: 800, to: micURL)

        let rendered = try RecordingSessionRecovery.renderOrphanedTracks(meetingID: meetingID, store: store)

        XCTAssertEqual(rendered, 0, "an existing non-empty WAV must never be overwritten")
        XCTAssertEqual(try fileSize(of: wavURL), 4_096)
        XCTAssertEqual(try fileSize(of: micURL), 800 * 4)
        XCTAssertTrue(store.hasRecoverableAudio(for: meetingID))
        XCTAssertFalse(try store.deleteSessionIfEmpty(for: meetingID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRenderCreatesManifestWhenTheDirectoryHasNone() throws {
        // The real-world May 19 case with an unreadable manifest: the PCM is
        // still the authority, so recovery rebuilds the manifest around it.
        let meetingID = UUID()
        let directory = try store.sessionDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFloatSamples(count: 8_000, to: directory.appendingPathComponent("segment-002.mic.pcm"))

        let rendered = try RecordingSessionRecovery.renderOrphanedTracks(meetingID: meetingID, store: store)

        XCTAssertEqual(rendered, 1)
        let session = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(session.segments.map(\.index), [2])
        XCTAssertEqual(session.segments[0].duration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try fileSize(of: directory.appendingPathComponent("segment-002.wav")), 44 + 16_000)
    }

    func testRenderSkipsAndLogsWhenTheSegmentWavIsAlreadyOccupied() throws {
        // The state the previous round reported as "no orphaned PCM tracks":
        // segment-001.wav holds samples and segment-001.mic.pcm is still
        // there. Nothing may move, and the finding has to say so — otherwise
        // 130 MB of audio goes unmentioned forever.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)
        let wavURL = directory.appendingPathComponent("segment-001.wav")
        let micURL = directory.appendingPathComponent("segment-001.mic.pcm")
        try Data(repeating: 0x41, count: 4_096).write(to: wavURL)
        try writeFloatSamples(count: 800, to: micURL)

        XCTAssertEqual(try RecordingSessionRecovery.renderOrphanedTracks(meetingID: meetingID, store: store), 0)
        XCTAssertEqual(try fileSize(of: wavURL), 4_096)
        XCTAssertEqual(try fileSize(of: micURL), 800 * 4)
        XCTAssertEqual(
            try RecordingSessionRecovery.scan(store: store),
            [.resumable(meetingID, segmentCount: 1, strandedPCM: [1])],
            "the stranded PCM must be reported, not silently dropped"
        )
    }

    func testRenderSegmentRefusesToOverwriteAnOccupiedWav() throws {
        // The guard head-on: through `renderOrphanedTracks` the inventory
        // already filters this segment out, so the guard is only reachable via
        // the seam — and a safety guard nothing can test is one nobody can
        // trust.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)
        let wavURL = directory.appendingPathComponent("segment-001.wav")
        let micURL = directory.appendingPathComponent("segment-001.mic.pcm")
        try Data(repeating: 0x41, count: 4_096).write(to: wavURL)
        try writeFloatSamples(count: 800, to: micURL)

        let rendered = try RecordingSessionRecovery.renderSegment(
            segmentNumber: 1,
            for: meetingID,
            slot: RecordingSessionRecovery.SegmentSlot(
                microphonePCM: micURL,
                microphonePCMByteCount: 800 * 4
            ),
            store: store
        )

        XCTAssertFalse(rendered)
        XCTAssertEqual(try fileSize(of: wavURL), 4_096)
        XCTAssertEqual(try fileSize(of: micURL), 800 * 4)
        XCTAssertEqual(try XCTUnwrap(store.loadSession(for: meetingID)).segments.count, 0)
    }

    func testScanContinuesPastAnUnlistableDirectory() throws {
        // One permission-denied folder among nine must not cost us the other
        // eight — the 130 MB PCM pair could be in any of them.
        let unlistableID = UUID()
        let healthyID = UUID()
        try store.createSession(for: unlistableID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 4_096, to: "segment-001.mic.pcm", for: unlistableID)
        try store.createSession(for: healthyID, systemAudioEnabled: true, selectedInputDeviceID: nil)

        let root = rootURL!
        let blindStore = RecordingResumeSessionStore(
            fileManager: UnlistableFileManager(unlistableDirectoryName: unlistableID.uuidString),
            baseDirectoryProvider: { root }
        )

        let findings = try RecordingSessionRecovery.scan(store: blindStore)

        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(
            findings.contains(.resumable(unlistableID, segmentCount: 0, strandedPCM: [])),
            "an uninspectable directory must be kept, never called disposable"
        )
        XCTAssertTrue(findings.contains(.disposable(healthyID)), "the other directories are still classified")
    }

    // MARK: - adoptOrphanedSegments

    func testAdoptOrphanedSegmentsAppendsStrayWavsToTheManifest() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 2_048, to: "segment-001.wav", for: meetingID)
        try write(bytes: 4_096, to: "segment-002.wav", for: meetingID)
        // A header-only WAV carries no samples and must not be adopted.
        try write(bytes: 44, to: "segment-003.wav", for: meetingID)

        let adopted = try RecordingSessionRecovery.adoptOrphanedSegments(meetingID: meetingID, store: store)

        XCTAssertEqual(adopted, 2)
        let session = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(session.segments.map(\.index), [1, 2])
        XCTAssertEqual(session.nextSegmentNumber, 3)
        // Idempotent: a second pass finds nothing left to adopt.
        XCTAssertEqual(try RecordingSessionRecovery.adoptOrphanedSegments(meetingID: meetingID, store: store), 0)
    }

    // MARK: - Coordinator (what launch recovery actually does)

    func testCoordinatorKeepsTheEmptySessionOfAPausedMeeting() throws {
        // The only deletion recovery is allowed to make is `deleteSessionIfEmpty`
        // on a `.disposable` finding — and not even that while a meeting is
        // paused on it: Resume/Stop still read the manifest, and deleting it
        // would strand the meeting on `RecordingError.noActiveRecording`.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)

        let outcome = RecordingSessionRecoveryCoordinator.repair(
            findings: try RecordingSessionRecovery.scan(store: store),
            store: store,
            activeMeetingIDs: [meetingID]
        )

        XCTAssertEqual(outcome.deletedSessions, 0)
        XCTAssertEqual(outcome.keptDisposableSessions, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(try store.loadSession(for: meetingID))
    }

    func testCoordinatorDeletesTheEmptySessionNoMeetingIsOn() throws {
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)

        let outcome = RecordingSessionRecoveryCoordinator.repair(
            findings: try RecordingSessionRecovery.scan(store: store),
            store: store,
            activeMeetingIDs: []
        )

        XCTAssertEqual(outcome.deletedSessions, 1)
        XCTAssertEqual(outcome.keptDisposableSessions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCoordinatorRendersOrphanedPCMAndFlipsAStaleRecordingMeetingToPaused() throws {
        // The scenario that made Resume fail with "There is no active recording
        // to stop.": raw PCM on disk, nothing in the manifest. After recovery
        // the audio is a manifest segment, so the meeting is genuinely resumable
        // and its stale `.recording` status becomes `.pausedRecording`.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)
        try writeFloatSamples(count: 8_000, to: directory.appendingPathComponent("segment-001.mic.pcm"))

        let outcome = RecordingSessionRecoveryCoordinator.repair(
            findings: try RecordingSessionRecovery.scan(store: store),
            store: store,
            activeMeetingIDs: [meetingID]
        )

        XCTAssertEqual(outcome.renderedSegments, 1)
        XCTAssertEqual(outcome.resumableMeetingIDs, [meetingID])
        XCTAssertEqual(outcome.strandedSegments, 0)
        let session = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(session.segments.map(\.index), [1])
        // `AudioRecordingService.hasResumableSession` is "manifest or audio", and
        // recovery just produced both.
        XCTAssertTrue(store.hasRecoverableAudio(for: meetingID))
        XCTAssertEqual(
            PausedRecordingRecovery.recoveredStatus(current: .recording, hasResumableSession: true),
            .pausedRecording
        )
    }

    func testCoordinatorAdoptsAStrayWavIntoTheManifest() throws {
        // A finalized WAV the manifest never heard about would never reach a
        // transcript, however healthy the audio is.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        try write(bytes: 2_048, to: "segment-001.wav", for: meetingID)

        let outcome = RecordingSessionRecoveryCoordinator.repair(
            findings: try RecordingSessionRecovery.scan(store: store),
            store: store,
            activeMeetingIDs: []
        )

        XCTAssertEqual(outcome.adoptedSegments, 1)
        XCTAssertEqual(outcome.resumableMeetingIDs, [meetingID])
        let session = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(session.segments.map(\.index), [1])
    }

    func testCoordinatorReportsStrandedPCMWithoutTouchingIt() throws {
        // PCM next to a WAV that already carries samples: recovery can neither
        // render nor delete it, so the count has to reach the user.
        let meetingID = UUID()
        try store.createSession(for: meetingID, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let directory = try store.sessionDirectory(for: meetingID)
        let wavURL = directory.appendingPathComponent("segment-001.wav")
        let micURL = directory.appendingPathComponent("segment-001.mic.pcm")
        try Data(repeating: 0x41, count: 4_096).write(to: wavURL)
        try writeFloatSamples(count: 800, to: micURL)

        let outcome = RecordingSessionRecoveryCoordinator.repair(
            findings: try RecordingSessionRecovery.scan(store: store),
            store: store,
            activeMeetingIDs: []
        )

        XCTAssertEqual(outcome.strandedSegments, 1)
        XCTAssertEqual(outcome.resumableMeetingIDs, [meetingID])
        XCTAssertEqual(try fileSize(of: wavURL), 4_096)
        XCTAssertEqual(try fileSize(of: micURL), 800 * 4)
    }

    // MARK: - Helpers

    private func write(bytes count: Int, to fileName: String, for meetingID: UUID) throws {
        let directory = try store.sessionDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: count).write(to: directory.appendingPathComponent(fileName))
    }

    /// Writes `count` float32 samples of a mild constant level — enough for the
    /// mixdown to produce a non-empty Int16 track.
    private func writeFloatSamples(count: Int, to url: URL) throws {
        let samples = [Float](repeating: 0.25, count: count)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url)
    }

    private func fileSize(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? Int)
    }
}

/// Stands in for a session directory the process may not list: a revoked
/// sandbox extension, a permissions change, a folder mid-deletion.
private final class UnlistableFileManager: FileManager {
    private let unlistableDirectoryName: String

    init(unlistableDirectoryName: String) {
        self.unlistableDirectoryName = unlistableDirectoryName
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.lastPathComponent == unlistableDirectoryName {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
