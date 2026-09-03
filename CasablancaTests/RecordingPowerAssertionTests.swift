import CoreAudio
import Foundation
import XCTest
@testable import Casablanca

/// A 75-minute recording was lost when the Mac idle-slept with the microphone
/// live: macOS drops coreaudiod's own idle-sleep assertion once the display
/// sleeps, and the app held none of its own. These tests pin the assertion to
/// the two long-running jobs that must outlive an idle display — recording and
/// transcription — and, just as importantly, pin its release: an assertion left
/// standing keeps the machine awake for the rest of the day.
@MainActor
final class RecordingPowerAssertionTests: XCTestCase {
    private static let recordingReason = "Casablanca is recording a meeting"
    private static let transcribingReason = "Casablanca is transcribing a meeting"

    // MARK: - Recording

    func testStartRecordingHoldsAssertionUntilStopped() async throws {
        let rootURL = try makeTemporaryDirectory()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let sleepPreventer = FakeSleepPreventer()
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                FakeRecordingSession(outputURL: outputURL, duration: 8)
            },
            makeFinalOutputURL: { _ in rootURL.appendingPathComponent("final.wav") },
            mergeSegments: { _, outputURL in
                try Data("merged".utf8).write(to: outputURL)
                return 8
            },
            sleepPreventer: sleepPreventer
        )

        try await service.startRecording(for: meeting)

        XCTAssertEqual(sleepPreventer.activeCount, 1, "A live recording must hold an idle-sleep assertion")
        XCTAssertEqual(sleepPreventer.reasons, [Self.recordingReason])

        _ = try await service.stopRecording(for: meeting)

        XCTAssertEqual(sleepPreventer.activeCount, 0, "Stopping must release the assertion, not leave the Mac awake")
    }

    func testPauseAndInterruptReleaseAssertion() async throws {
        let rootURL = try makeTemporaryDirectory()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let sleepPreventer = FakeSleepPreventer()
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                FakeRecordingSession(outputURL: outputURL, duration: 8)
            },
            sleepPreventer: sleepPreventer
        )

        try await service.startRecording(for: meeting)
        XCTAssertEqual(sleepPreventer.activeCount, 1)

        _ = try await service.pauseRecording()
        XCTAssertEqual(sleepPreventer.activeCount, 0, "A paused recording is not recording — release the assertion")

        try await service.resumeRecording(for: meeting)
        XCTAssertEqual(sleepPreventer.activeCount, 1, "Resuming must take the assertion again")

        let outcome = await service.handleSystemInterrupt(reason: .systemSleep)
        guard case .segmentFinalized = outcome else {
            return XCTFail("Expected the interrupted segment to be finalized, got \(outcome)")
        }
        XCTAssertEqual(sleepPreventer.activeCount, 0, "An interrupt tears the session down — the assertion goes with it")
        XCTAssertEqual(sleepPreventer.beginCount, 2, "One assertion per started segment, no more")
    }

    func testFailedStartReleasesAssertion() async throws {
        let rootURL = try makeTemporaryDirectory()
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let sleepPreventer = FakeSleepPreventer()
        let meeting = Meeting(title: "No Microphone", date: .now, status: .recording)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                FailingStartRecordingSession(outputURL: outputURL)
            },
            sleepPreventer: sleepPreventer
        )

        do {
            try await service.startRecording(for: meeting)
            XCTFail("A session whose start() throws must fail the start")
        } catch {
            // expected
        }

        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(sleepPreventer.activeCount, 0, "A failed start must leave no assertion standing")
        XCTAssertEqual(
            sleepPreventer.beginCount, 0,
            "The assertion belongs to a session that is actually running: take it only after start() succeeds"
        )
    }

    // MARK: - Transcription

    /// The Mac also slept for 37 minutes in the middle of a transcription.
    /// `TranscriptionService` builds its WhisperKit pipeline internally, so this
    /// drives the two paths reachable without a model: a missing file (must
    /// throw *before* the assertion is taken) and an unreadable audio file
    /// (throws after it, so the existing `defer` has to release it).
    func testTranscribeHoldsAssertionForDuration() async throws {
        let rootURL = try makeTemporaryDirectory()
        let sleepPreventer = FakeSleepPreventer()
        let service = TranscriptionService(sleepPreventer: sleepPreventer)

        let missingURL = rootURL.appendingPathComponent("gone.wav")
        do {
            _ = try await service.transcribe(fileURL: missingURL)
            XCTFail("A missing audio file must throw")
        } catch {
            // expected
        }
        XCTAssertEqual(
            sleepPreventer.beginCount, 0,
            "Nothing is transcribing yet — a missing file must throw before the assertion is taken"
        )

        let unreadableURL = rootURL.appendingPathComponent("unreadable.wav")
        try Data(repeating: 0x41, count: 2_048).write(to: unreadableURL)
        do {
            _ = try await service.transcribe(fileURL: unreadableURL)
            XCTFail("An unreadable audio file must throw")
        } catch {
            // expected
        }

        XCTAssertEqual(sleepPreventer.beginCount, 1, "A started transcription takes the assertion exactly once")
        XCTAssertEqual(sleepPreventer.reasons, [Self.transcribingReason])
        XCTAssertEqual(
            sleepPreventer.activeCount, 0,
            "The transcribe() defer must release the assertion however transcription ends"
        )
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// Counts assertions instead of touching the power management system.
private final class FakeSleepPreventer: SleepPreventing {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var reasons: [String] = []

    /// Assertions currently held. Must be 0 whenever nothing long-running is in
    /// flight; anything else keeps the Mac awake indefinitely.
    var activeCount: Int { beginCount - endCount }

    func begin(reason: String) -> SleepPreventionToken {
        beginCount += 1
        reasons.append(reason)
        return SleepPreventionToken { [weak self] in
            self?.endCount += 1
        }
    }
}

/// Minimal stand-in for a running capture session: `stop()` always reports a
/// finalized segment. Mirrors `MeetingStartFlowTests`' fake, kept local because
/// that one is file-private.
private final class FakeRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = true
    let systemAudioUnavailableError: Error? = nil
    private let duration: TimeInterval

    init(outputURL: URL, duration: TimeInterval) {
        self.outputURL = outputURL
        self.duration = duration
    }

    func start() async throws {}
    func stop() async throws -> RecordingResult {
        RecordingResult(outputURL: outputURL, duration: duration)
    }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}

/// A session that never gets going — a denied microphone, a device that
/// vanished between selection and start.
private final class FailingStartRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = false
    let systemAudioUnavailableError: Error? = nil

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        throw RecordingError.microphonePermissionDenied
    }
    func stop() async throws -> RecordingResult {
        throw RecordingError.noCapturedAudio
    }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}
