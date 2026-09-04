import SwiftData
import XCTest
@testable import Casablanca

/// The post-recording pipeline used to live inside `TranscriptionView.task`, so
/// navigating away cancelled it and coming back started a second concurrent
/// transcription. These tests pin the two things that move: the pipeline is a
/// value type with injectable steps (so its ORDER is assertable — compression
/// last, after the transcript file and the export), and the run is owned by the
/// service (so a re-trigger is a no-op and Cancel actually stops it).
@MainActor
final class PostTranscriptionPipelineTests: XCTestCase {

    // MARK: - Pipeline order

    func testPipelineOrderIsTranscriptThenCompletedThenExportThenCompress() async throws {
        let context = try makeInMemoryModelContext()
        let wavURL = try makeTemporaryWAV()
        let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        let meeting = Meeting(title: "Sprint Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = wavURL.path
        meeting.status = .processing
        context.insert(meeting)

        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        defaults.set("Casablanca: casa blanca", forKey: AppPreferenceKey.terminologyList)

        let recorder = StepRecorder()
        let pipeline = PostTranscriptionPipeline(
            correctTerminology: { transcript, entries in
                recorder.record("terminology", meeting: meeting)
                XCTAssertFalse(entries.isEmpty, "The corrector only runs when there are entries to apply")
                XCTAssertEqual(transcript, "[00:00] casa blanca is great")
                return "[00:00] Casablanca is great"
            },
            saveTranscript: { savedMeeting, _ in
                recorder.record("saveTranscript", meeting: savedMeeting)
                return URL(fileURLWithPath: "/tmp/transcript.txt")
            },
            export: { exportedMeeting in
                recorder.record("export", meeting: exportedMeeting)
            },
            compress: { url in
                recorder.record("compress", meeting: meeting)
                XCTAssertEqual(url, wavURL)
                return m4aURL
            },
            defaults: defaults
        )

        await pipeline.run(
            meeting: meeting,
            result: makeResult(text: "casa blanca is great"),
            recordingURL: wavURL,
            modelContext: context
        )

        XCTAssertEqual(
            recorder.steps,
            ["terminology", "saveTranscript", "export", "compress"],
            "Compression is minutes of CPU and nothing downstream needs it, so it must run LAST"
        )
        XCTAssertEqual(
            recorder.statuses,
            [.processing, .completed, .completed, .completed],
            "The meeting must already read as completed before the transcript file, export and compression run"
        )
        XCTAssertEqual(
            recorder.transcripts,
            [nil, "[00:00] Casablanca is great", "[00:00] Casablanca is great", "[00:00] Casablanca is great"],
            "The corrected transcript is on the meeting before anything downstream of it runs"
        )
        XCTAssertEqual(meeting.transcript, "[00:00] Casablanca is great")
        XCTAssertEqual(meeting.rawTranscript, "[00:00] casa blanca is great", "The uncorrected text is kept alongside")
        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.recordingFileURL, m4aURL.path, "A successful compression repoints the meeting")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wavURL.path),
            "The WAV is no longer referenced, so its disk space is reclaimed"
        )
    }

    func testCompressionFailureKeepsWavPath() async throws {
        let context = try makeInMemoryModelContext()
        let wavURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let meeting = Meeting(title: "Retro", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = wavURL.path
        meeting.status = .processing
        context.insert(meeting)

        let recorder = StepRecorder()
        let pipeline = PostTranscriptionPipeline(
            correctTerminology: { transcript, _ in
                XCTFail("Terminology correction is off, so the corrector must not be called")
                return transcript
            },
            saveTranscript: { savedMeeting, _ in
                recorder.record("saveTranscript", meeting: savedMeeting)
                return URL(fileURLWithPath: "/tmp/transcript.txt")
            },
            export: { exportedMeeting in
                recorder.record("export", meeting: exportedMeeting)
            },
            compress: { _ in
                recorder.record("compress", meeting: meeting)
                throw CocoaError(.fileWriteOutOfSpace)
            },
            defaults: makeDefaults()
        )

        await pipeline.run(
            meeting: meeting,
            result: makeResult(text: "hello"),
            recordingURL: wavURL,
            modelContext: context
        )

        XCTAssertEqual(recorder.steps, ["saveTranscript", "export", "compress"])
        XCTAssertEqual(
            meeting.recordingFileURL,
            wavURL.path,
            "A failed compression must leave the meeting pointing at the WAV"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wavURL.path),
            "The recording is never lost to a failed compression"
        )
        XCTAssertEqual(meeting.transcript, "[00:00] hello", "The transcript survives a failed compression")
        XCTAssertNil(meeting.rawTranscript, "With correction off there is no raw transcript to keep")
        XCTAssertEqual(meeting.status, .completed)
    }

    // MARK: - Service-owned background run

    /// `transcribeInBackground` cannot reach a real WhisperKit in a test, so the
    /// transcription step itself is driven through the service's DEBUG seam; the
    /// ownership behaviour under test (no-op re-trigger, cancel) is all around it.
    func testSecondBackgroundRunForSameMeetingIsNoOp() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Standup", date: Date(timeIntervalSince1970: 1_700_000_000))
        // Already-compressed, so the live pipeline's compression step is skipped:
        // this test is about ownership, not about re-encoding.
        meeting.recordingFileURL = "/tmp/does-not-matter.m4a"
        context.insert(meeting)

        let service = TranscriptionService(
            sleepPreventer: FakeSleepPreventer(),
            memoryPressureMonitor: FakeMemoryPressureMonitor()
        )
        let runs = Counter()
        service.transcribeOverrideForTesting = { _, _ in
            runs.increment()
            return makeResult(text: "hello")
        }

        service.transcribeInBackground(
            meeting: meeting,
            modelContext: context,
            terminologyService: TerminologyService(),
            exportReporter: nil
        )
        XCTAssertEqual(service.transcribingMeetingID, meeting.id)

        // The re-trigger a re-appearing view produces: it must not start a second
        // concurrent transcription on the same WhisperKit instance.
        service.transcribeInBackground(
            meeting: meeting,
            modelContext: context,
            terminologyService: TerminologyService(),
            exportReporter: nil
        )

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(runs.value, 1, "A second run for the meeting already transcribing is ignored")
        XCTAssertNil(service.transcribingMeetingID, "The run clears itself on the way out")
        XCTAssertEqual(service.lastCompletedMeetingID, meeting.id, "A clean run reports the meeting it finished")
        XCTAssertNil(service.lastError)
    }

    func testCancelStopsBackgroundTask() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Bilateral", date: Date(timeIntervalSince1970: 1_700_000_000))
        // Already-compressed, so the live pipeline's compression step is skipped:
        // this test is about ownership, not about re-encoding.
        meeting.recordingFileURL = "/tmp/does-not-matter.m4a"
        context.insert(meeting)

        let service = TranscriptionService(
            sleepPreventer: FakeSleepPreventer(),
            memoryPressureMonitor: FakeMemoryPressureMonitor()
        )
        let started = Counter()
        service.transcribeOverrideForTesting = { _, _ in
            started.increment()
            // Stands in for a long transcription: it ends only when cancelled.
            try await Task.sleep(nanoseconds: 60_000_000_000)
            XCTFail("A cancelled run must not reach its result")
            return makeResult(text: "unreachable")
        }

        service.transcribeInBackground(
            meeting: meeting,
            modelContext: context,
            terminologyService: TerminologyService(),
            exportReporter: nil
        )
        service.cancel()

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(started.value, 1)
        XCTAssertNil(service.transcribingMeetingID, "Cancel ends the service-owned run")
        XCTAssertNil(service.lastCompletedMeetingID, "A cancelled run never completes the pipeline")
        XCTAssertNil(service.lastError, "Cancel is user intent, not a failure to surface")
        XCTAssertNil(meeting.transcript, "A cancelled run writes no transcript")
    }

    // MARK: - Helpers

    private func makeInMemoryModelContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "post-transcription-\(UUID().uuidString)")!
    }

    private func makeTemporaryWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casablanca-pipeline-\(UUID().uuidString).wav")
        try Data("not really audio".utf8).write(to: url)
        return url
    }
}

/// One transcript segment's worth of result, enough for `formattedTranscript`.
private func makeResult(text: String) -> TranscriptionResult {
    TranscriptionResult(
        segments: [TranscriptSegment(startTime: 0, endTime: 1, text: text)],
        fullText: text,
        duration: 1
    )
}

/// Records the pipeline steps in the order they run, together with the meeting
/// state visible at each one — the order alone would not prove that the meeting
/// reads as completed before the export and the compression.
@MainActor
private final class StepRecorder {
    private(set) var steps: [String] = []
    private(set) var statuses: [MeetingStatus] = []
    private(set) var transcripts: [String?] = []

    func record(_ step: String, meeting: Meeting) {
        steps.append(step)
        statuses.append(meeting.status)
        transcripts.append(meeting.transcript)
    }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class FakeSleepPreventer: SleepPreventing {
    func begin(reason: String) -> SleepPreventionToken {
        SleepPreventionToken {}
    }
}

private final class FakeMemoryPressureMonitor: MemoryPressureMonitoring {
    func start(handler: @escaping @Sendable () -> Void) {}
}
