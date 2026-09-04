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

    /// `transcribeInBackground` can reach neither a real WhisperKit nor the live
    /// pipeline in a test, so both are driven through the service's DEBUG seams:
    /// the live pipeline reads `UserDefaults.standard`, writes into the real
    /// Application Support, exports into the user's real Obsidian vault and can
    /// make a billed LLM terminology call. Everything under test here — the
    /// guards, the wind-down wait, the cancel path — is production code.
    func testSecondBackgroundRunForSameMeetingIsNoOp() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = makeMeeting(titled: "Standup", in: context)
        let service = makeService()
        let pipelineRuns = EventLog()
        service.pipelineOverrideForTesting = makeFakePipeline(log: pipelineRuns)

        let runs = Counter()
        service.transcribeOverrideForTesting = { _, _ in
            runs.increment()
            return makeResult(text: "hello")
        }

        start(service, meeting, context)
        XCTAssertEqual(service.transcribingMeetingID, meeting.id)

        // The re-trigger a re-appearing view produces: it must not start a second
        // concurrent transcription on the same WhisperKit instance.
        start(service, meeting, context)

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(runs.value, 1, "A second run for the meeting already transcribing is ignored")
        XCTAssertEqual(pipelineRuns.events, ["pipeline"], "…and the pipeline runs once, not twice")
        XCTAssertNil(service.transcribingMeetingID, "The run clears itself on the way out")
        XCTAssertEqual(service.lastCompletedMeetingID, meeting.id, "A clean run reports the meeting it finished")
        XCTAssertNil(service.lastError, "A no-op re-trigger is not an error: that run is genuinely showing")
    }

    /// The refusal that would otherwise be invisible. Callers flip the meeting to
    /// `.processing` *before* calling (NotesEditorView after Stop, ContentView's
    /// "Transcribe"), so a silent refusal leaves it spinning on a run that does
    /// not exist, with `.task` unable to re-fire and Cancel disabled.
    func testRejectedRunForAnotherMeetingSurfacesAnError() async throws {
        let context = try makeInMemoryModelContext()
        let running = makeMeeting(titled: "Sprint Review", in: context)
        let refused = makeMeeting(titled: "Retro", in: context)
        let service = makeService()
        service.pipelineOverrideForTesting = makeFakePipeline(log: EventLog())

        let runs = Counter()
        let gate = Gate()
        service.transcribeOverrideForTesting = { _, _ in
            runs.increment()
            await gate.wait()
            return makeResult(text: "hello")
        }

        start(service, running, context)
        start(service, refused, context)

        XCTAssertEqual(service.transcribingMeetingID, running.id, "The live run keeps the service")
        guard case .anotherTranscriptionInProgress(let blockingTitle) = service.lastError else {
            return XCTFail("A refused start must surface an error, got \(String(describing: service.lastError))")
        }
        XCTAssertEqual(blockingTitle, "Sprint Review", "The error names what is blocking the start")
        XCTAssertEqual(
            service.lastError?.localizedDescription,
            "Another meeting (Sprint Review) is still being transcribed. Try again when it finishes.",
            "The alert has to read as an instruction, not as a failure"
        )

        gate.open()
        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(runs.value, 1, "The refused meeting never started a decode of its own")
        XCTAssertEqual(
            service.lastCompletedMeetingID,
            running.id,
            "Only the run that was already going completes"
        )
    }

    /// Retry straight after Cancel. `cancel()` leaves `transcribingMeetingID` set
    /// until the old task unwinds, so a re-trigger in that window used to be
    /// refused — leaving the meeting stuck. It now waits the predecessor out and
    /// then runs, which also keeps the two decodes off one WhisperKit instance.
    func testRestartAfterCancelWaitsForWindDownThenRuns() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = makeMeeting(titled: "Bilateral", in: context)
        let service = makeService()
        let log = EventLog()
        service.pipelineOverrideForTesting = makeFakePipeline(log: log)

        let decodes = Counter()
        service.transcribeOverrideForTesting = { _, _ in
            decodes.increment()
            let decode = decodes.value
            log.append("decode \(decode) started")
            if decode == 1 {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    log.append("decode 1 unwound")
                    throw error
                }
            }
            log.append("decode \(decode) finished")
            return makeResult(text: "hello")
        }

        start(service, meeting, context)
        service.cancel()
        // The window the fix is about: cancelled, but not yet unwound.
        start(service, meeting, context)

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(
            log.events,
            ["decode 1 started", "decode 1 unwound", "decode 2 started", "decode 2 finished", "pipeline"],
            "The replacement run starts only after the cancelled one has unwound"
        )
        XCTAssertEqual(decodes.value, 2, "The restart really ran; it was not swallowed as a duplicate")
        XCTAssertEqual(service.lastCompletedMeetingID, meeting.id)
        XCTAssertNil(service.transcribingMeetingID)
        XCTAssertNil(service.lastError, "Neither the cancel nor the restart is a failure")
    }

    func testCancelStopsBackgroundTask() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = makeMeeting(titled: "Week start", in: context)
        let service = makeService()
        let pipelineRuns = EventLog()
        service.pipelineOverrideForTesting = makeFakePipeline(log: pipelineRuns)

        let started = Counter()
        let gate = Gate()
        let cancellationReachedTheDecode = Flag()
        service.transcribeOverrideForTesting = { _, _ in
            started.increment()
            // Stands in for a long transcription: it waits, and on release
            // reports whether the cancellation reached this far IN — proving the
            // inner step is cancelled, not just the task wrapping it.
            await gate.wait()
            cancellationReachedTheDecode.set(Task.isCancelled)
            try Task.checkCancellation()
            XCTFail("A cancelled run must not reach its result")
            return makeResult(text: "unreachable")
        }

        start(service, meeting, context)
        service.cancel()
        gate.open()

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(started.value, 1)
        XCTAssertTrue(
            cancellationReachedTheDecode.value,
            "Cancellation has to propagate INTO the transcription step, not stop at the task boundary"
        )
        XCTAssertEqual(pipelineRuns.events, [], "A cancelled run never reaches the pipeline")
        XCTAssertNil(service.transcribingMeetingID, "Cancel ends the service-owned run")
        XCTAssertNil(service.lastCompletedMeetingID, "A cancelled run never completes the pipeline")
        XCTAssertNil(service.lastError, "Cancel is user intent, not a failure to surface")
        XCTAssertNil(meeting.transcript, "A cancelled run writes no transcript")
    }

    // MARK: - Helpers

    private func makeService() -> TranscriptionService {
        TranscriptionService(
            sleepPreventer: FakeSleepPreventer(),
            memoryPressureMonitor: FakeMemoryPressureMonitor()
        )
    }

    private func makeMeeting(titled title: String, in context: ModelContext) -> Meeting {
        let meeting = Meeting(title: title, date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = "/tmp/does-not-matter.wav"
        context.insert(meeting)
        return meeting
    }

    /// A pipeline whose every step is a fake reading scratch preferences, so no
    /// service-level test can touch `UserDefaults.standard`, the real
    /// Application Support, the user's Obsidian vault, or an LLM. Appends
    /// "pipeline" to `log` from the transcript-saving step, which always runs, so
    /// a test can tell whether the pipeline was reached at all.
    private func makeFakePipeline(log: EventLog) -> PostTranscriptionPipeline {
        PostTranscriptionPipeline(
            correctTerminology: { transcript, _ in transcript },
            saveTranscript: { _, _ in
                log.append("pipeline")
                return URL(fileURLWithPath: "/dev/null")
            },
            export: { _ in },
            compress: { url in url },
            defaults: makeDefaults()
        )
    }

    /// Starts a background run with the fakes the tests share.
    private func start(_ service: TranscriptionService, _ meeting: Meeting, _ context: ModelContext) {
        service.transcribeInBackground(
            meeting: meeting,
            modelContext: context,
            terminologyService: TerminologyService(),
            exportReporter: nil
        )
    }

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

/// An ordered list of what happened, for the assertions that are about order.
@MainActor
private final class EventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

@MainActor
private final class Flag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}

/// Holds a fake transcription open until the test releases it, so "while a run
/// is in flight" is a fact rather than a race.
private actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func openNow() {
        isOpen = true
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}

extension Gate {
    /// Callable from the main-actor tests without an await ceremony at each site.
    nonisolated func open() {
        Task { await self.openNow() }
    }
}

private final class FakeSleepPreventer: SleepPreventing {
    func begin(reason: String) -> SleepPreventionToken {
        SleepPreventionToken {}
    }
}

private final class FakeMemoryPressureMonitor: MemoryPressureMonitoring {
    func start(handler: @escaping @Sendable () -> Void) {}
}
