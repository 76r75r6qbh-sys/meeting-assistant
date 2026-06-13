import XCTest
@testable import Casablanca

final class MeetingPipelineStateTests: XCTestCase {

    // Convenience builder with sensible "nothing happening" defaults.
    private func make(
        isThisMeetingTranscribing: Bool = false,
        transcriptionProgress: Double = 0,
        isSummarizingThisMeeting: Bool = false,
        summarizationPhase: SummarizationService.SummarizationPhase = .idle,
        summarizationStartedAt: Date? = nil,
        summarizationError: String? = nil,
        summarizationWarning: String? = nil,
        autoExportFailure: AutoExportFailure? = nil,
        meetingStatus: MeetingStatus = .completed,
        hasTranscript: Bool = true,
        hasSummary: Bool = true,
        autoSummarize: Bool = false,
        autoExport: Bool = false
    ) -> MeetingPipelinePresentation {
        MeetingPipelinePresentation(
            isThisMeetingTranscribing: isThisMeetingTranscribing,
            transcriptionProgress: transcriptionProgress,
            isSummarizingThisMeeting: isSummarizingThisMeeting,
            summarizationPhase: summarizationPhase,
            summarizationStartedAt: summarizationStartedAt,
            summarizationError: summarizationError,
            summarizationWarning: summarizationWarning,
            autoExportFailure: autoExportFailure,
            meetingStatus: meetingStatus,
            hasTranscript: hasTranscript,
            hasSummary: hasSummary,
            autoSummarize: autoSummarize,
            autoExport: autoExport
        )
    }

    // MARK: - Stage derivation

    func testTranscribingStage() {
        let p = make(isThisMeetingTranscribing: true, transcriptionProgress: 0.42, meetingStatus: .processing)
        XCTAssertEqual(p.stage, .transcribing(progress: 0.42))
        XCTAssertTrue(p.isActive)
        XCTAssertFalse(p.hasError)
    }

    func testSummarizingStage() {
        let started = Date()
        let p = make(
            isSummarizingThisMeeting: true,
            summarizationPhase: .sending,
            summarizationStartedAt: started,
            hasSummary: false
        )
        XCTAssertEqual(p.stage, .summarizing(startedAt: started))
        XCTAssertTrue(p.isActive)
    }

    func testSummarizingTakesPriorityOverStaleProcessing() {
        // Even if the meeting status is .processing, an active summary wins.
        let p = make(
            isSummarizingThisMeeting: true,
            summarizationPhase: .sending,
            meetingStatus: .processing
        )
        if case .summarizing = p.stage {} else { XCTFail("expected summarizing, got \(p.stage)") }
    }

    func testTranscribingTakesPriorityOverEverything() {
        let p = make(
            isThisMeetingTranscribing: true,
            transcriptionProgress: 0.1,
            isSummarizingThisMeeting: true,
            summarizationError: "boom",
            meetingStatus: .processing
        )
        XCTAssertEqual(p.stage, .transcribing(progress: 0.1))
    }

    func testSummarizationFailedStage() {
        let p = make(summarizationError: "model unreachable", hasSummary: false)
        XCTAssertEqual(p.stage, .failed(stage: .summarization, message: "model unreachable"))
        XCTAssertTrue(p.hasError)
        XCTAssertFalse(p.isActive)
    }

    func testExportFailedStage() {
        let failure = AutoExportFailure(meetingID: UUID(), destination: "Obsidian", message: "vault missing")
        let p = make(autoExportFailure: failure)
        XCTAssertEqual(p.stage, .failed(stage: .export, message: "vault missing"))
        XCTAssertTrue(p.hasError)
    }

    func testSummarizationErrorTakesPriorityOverExportFailure() {
        let failure = AutoExportFailure(meetingID: UUID(), destination: "Obsidian", message: "vault missing")
        let p = make(summarizationError: "sum boom", autoExportFailure: failure)
        XCTAssertEqual(p.stage, .failed(stage: .summarization, message: "sum boom"))
    }

    func testStaleProcessingBecomesTranscriptionFailed() {
        // .processing with nothing running ⇒ interrupted transcription.
        let p = make(meetingStatus: .processing, hasTranscript: false, hasSummary: false)
        if case .failed(let stage, _) = p.stage {
            XCTAssertEqual(stage, .transcription)
        } else {
            XCTFail("expected failed(transcription), got \(p.stage)")
        }
    }

    func testAutoSummarizePendingShowsSummarizingNext() {
        let p = make(meetingStatus: .completed, hasTranscript: true, hasSummary: false, autoSummarize: true)
        XCTAssertEqual(p.stage, .summarizing(startedAt: nil))
    }

    // MARK: - Warning vs error (Fix 1)

    func testWarningWithoutErrorIsNotAFailure() {
        // A SUCCESSFUL summary with a to-do hiccup: warning set, no error.
        let p = make(
            summarizationWarning: "Summary generated, but creating its to-dos failed.",
            hasSummary: true
        )
        // Stage stays a non-error terminal stage (.done) — NOT .failed.
        XCTAssertEqual(p.stage, .done)
        XCTAssertFalse(p.hasError)
        // And the warning is surfaced as a non-error notice.
        XCTAssertEqual(p.warning, "Summary generated, but creating its to-dos failed.")
    }

    func testErrorStillYieldsFailedAndSuppressesWarning() {
        // A real error takes precedence: .failed stage, and no warning rides along.
        let p = make(
            summarizationError: "model unreachable",
            summarizationWarning: "some caveat",
            hasSummary: false
        )
        XCTAssertEqual(p.stage, .failed(stage: .summarization, message: "model unreachable"))
        XCTAssertTrue(p.hasError)
        XCTAssertNil(p.warning)
    }

    func testNoWarningWhenNoneSet() {
        let p = make(hasSummary: true)
        XCTAssertNil(p.warning)
    }

    // MARK: - Pending vs active summarize (Fix 2)

    func testSummarizePendingIsNotActiveWork() {
        // Auto-summarize armed but nothing started: pending, not running.
        let p = make(meetingStatus: .completed, hasTranscript: true, hasSummary: false, autoSummarize: true)
        XCTAssertTrue(p.isSummarizePending)
        XCTAssertEqual(p.statusText, "Waiting to summarize…")
        // The summarize chip must read pending (no spinner), not active.
        XCTAssertEqual(p.chipState(for: .summarize), .pending)
        XCTAssertEqual(p.chipState(for: .transcribe), .done)
    }

    func testSummarizeActiveIsNotPending() {
        // A genuinely running summary (live + startedAt) is active, not pending.
        let started = Date()
        let p = make(
            isSummarizingThisMeeting: true,
            summarizationPhase: .sending,
            summarizationStartedAt: started,
            hasSummary: false
        )
        XCTAssertFalse(p.isSummarizePending)
        XCTAssertEqual(p.statusText, "Generating summary…")
        XCTAssertEqual(p.chipState(for: .summarize), .active)
    }

    func testDoneWhenNothingPending() {
        let p = make(meetingStatus: .completed, hasTranscript: true, hasSummary: true)
        XCTAssertEqual(p.stage, .done)
        XCTAssertFalse(p.isActive)
        XCTAssertFalse(p.hasError)
    }

    func testIdleLikeWhenNoAutoSummarizeAndNoSummary() {
        // No auto-summarize armed, has transcript but no summary, not processing:
        // there's no active stage and no error → treated as done (card hidden).
        let p = make(meetingStatus: .completed, hasTranscript: true, hasSummary: false, autoSummarize: false)
        XCTAssertEqual(p.stage, .done)
    }

    // MARK: - Retrying surfaces

    func testRetryingSurfacesInStatusText() {
        let p = make(
            isSummarizingThisMeeting: true,
            summarizationPhase: .retrying(attempt: 2, maxAttempts: 3),
            summarizationStartedAt: Date()
        )
        XCTAssertNotNil(p.retryAttempt)
        XCTAssertEqual(p.retryAttempt?.attempt, 2)
        XCTAssertEqual(p.retryAttempt?.maxAttempts, 3)
        XCTAssertEqual(p.statusText, "Retrying (2/3)…")
    }

    func testRetryingIgnoredWhenNotSummarizingThisMeeting() {
        let p = make(
            isSummarizingThisMeeting: false,
            summarizationPhase: .retrying(attempt: 2, maxAttempts: 3)
        )
        XCTAssertNil(p.retryAttempt)
    }

    // MARK: - Chip state

    func testChipStatesDuringTranscription() {
        let p = make(isThisMeetingTranscribing: true, transcriptionProgress: 0.5, meetingStatus: .processing)
        XCTAssertEqual(p.chipState(for: .transcribe), .active)
        XCTAssertEqual(p.chipState(for: .summarize), .pending)
        XCTAssertEqual(p.chipState(for: .export), .pending)
    }

    func testChipStatesDuringSummarization() {
        let p = make(isSummarizingThisMeeting: true, summarizationPhase: .sending, hasSummary: false)
        XCTAssertEqual(p.chipState(for: .transcribe), .done)
        XCTAssertEqual(p.chipState(for: .summarize), .active)
        XCTAssertEqual(p.chipState(for: .export), .pending)
    }

    func testChipStatesOnExportFailure() {
        let failure = AutoExportFailure(meetingID: UUID(), destination: "Obsidian", message: "x")
        let p = make(autoExportFailure: failure)
        XCTAssertEqual(p.chipState(for: .transcribe), .done)
        XCTAssertEqual(p.chipState(for: .summarize), .done)
        XCTAssertEqual(p.chipState(for: .export), .failed)
    }

    func testChipStatesWhenDone() {
        let p = make(hasSummary: true)
        XCTAssertEqual(p.chipState(for: .transcribe), .done)
        XCTAssertEqual(p.chipState(for: .summarize), .done)
        XCTAssertEqual(p.chipState(for: .export), .done)
    }

    // MARK: - Stale .processing recovery (pure)

    func testRecoveryNilWhenNotProcessing() {
        XCTAssertNil(StaleProcessingRecovery.recoveredStatus(
            currentStatus: .completed, hasTranscript: true, hasUserNotes: false, isAnyPipelineActive: false
        ))
    }

    func testRecoveryNilWhenPipelineActive() {
        // A genuinely-running pipeline must not be reset.
        XCTAssertNil(StaleProcessingRecovery.recoveredStatus(
            currentStatus: .processing, hasTranscript: false, hasUserNotes: false, isAnyPipelineActive: true
        ))
    }

    func testRecoveryWithTranscriptBecomesCompleted() {
        XCTAssertEqual(StaleProcessingRecovery.recoveredStatus(
            currentStatus: .processing, hasTranscript: true, hasUserNotes: false, isAnyPipelineActive: false
        ), .completed)
    }

    func testRecoveryNoTranscriptWithNotesBecomesNotesOnly() {
        XCTAssertEqual(StaleProcessingRecovery.recoveredStatus(
            currentStatus: .processing, hasTranscript: false, hasUserNotes: true, isAnyPipelineActive: false
        ), .notesOnly)
    }

    func testRecoveryNoTranscriptNoNotesBecomesCompleted() {
        XCTAssertEqual(StaleProcessingRecovery.recoveredStatus(
            currentStatus: .processing, hasTranscript: false, hasUserNotes: false, isAnyPipelineActive: false
        ), .completed)
    }
}
