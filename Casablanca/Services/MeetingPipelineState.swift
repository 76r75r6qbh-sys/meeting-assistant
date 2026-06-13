import Foundation

/// A stage in the post-recording processing pipeline. Pure value type — no
/// SwiftUI — so stage derivation is fully unit-testable.
enum PipelineStage: Equatable {
    case idle
    case transcribing(progress: Double)
    case summarizing(startedAt: Date?)
    case exporting
    case failed(stage: FailureStage, message: String)
    case done

    /// Which concrete stage failed, so the UI can offer a targeted "Retry" that
    /// re-runs only that step.
    enum FailureStage: Equatable {
        case transcription
        case summarization
        case export
    }
}

/// The three user-visible stages, in pipeline order. Drives the stage-chip row
/// (Transcribe → Summarize → Export).
enum PipelineStageKind: Int, CaseIterable, Equatable {
    case transcribe
    case summarize
    case export

    var title: String {
        switch self {
        case .transcribe: return "Transcribe"
        case .summarize: return "Summarize"
        case .export: return "Export"
        }
    }

    var systemImage: String {
        switch self {
        case .transcribe: return "waveform"
        case .summarize: return "sparkles"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// How a single chip in the stage row should render.
enum PipelineChipState: Equatable {
    /// Not reached yet (dimmed).
    case pending
    /// Currently running (tinted / spinner).
    case active
    /// Finished successfully (checkmark).
    case done
    /// This stage failed (error tint).
    case failed
}

/// PURE presentation model deriving the current pipeline stage for a SPECIFIC
/// meeting from plain inputs. It deliberately takes scalar values rather than
/// the live services so it can be constructed and tested without SwiftUI, the
/// app environment, or a running model context. The view builds it from the
/// services each render.
struct MeetingPipelinePresentation {
    let stage: PipelineStage

    /// A non-fatal notice from a stage that otherwise SUCCEEDED (e.g. the summary
    /// was generated but creating its to-dos failed). Surfaced as a muted, NON-
    /// destructive notice in the card — never a red failed chip and never a Retry.
    /// Populated only when there is no real `errorMessage` (a real error takes
    /// precedence and drives `.failed`).
    let warning: String?

    /// Inputs captured for chip-state derivation and status text.
    let autoSummarize: Bool
    let autoExport: Bool

    /// Whether the shared summarization service is LIVE for this meeting. A live
    /// summary is genuinely-running even if `summarizationStartedAt` is briefly
    /// nil, so this guards `isSummarizePending` against false positives.
    private let isSummarizingThisMeeting: Bool

    /// `retrying` attempt info, surfaced from the summarization phase, so the UI
    /// can show "Retrying (2/3)…" without re-reading the service.
    let retryAttempt: (attempt: Int, maxAttempts: Int)?

    init(
        // Transcription
        isThisMeetingTranscribing: Bool,
        transcriptionProgress: Double,
        // Summarization (service is app-wide; scope by meeting id)
        isSummarizingThisMeeting: Bool,
        summarizationPhase: SummarizationService.SummarizationPhase,
        summarizationStartedAt: Date?,
        summarizationError: String?,
        summarizationWarning: String? = nil,
        // Export
        autoExportFailure: AutoExportFailure?,
        // Meeting state
        meetingStatus: MeetingStatus,
        hasTranscript: Bool,
        hasSummary: Bool,
        // Prefs
        autoSummarize: Bool,
        autoExport: Bool
    ) {
        self.autoSummarize = autoSummarize
        self.autoExport = autoExport
        self.isSummarizingThisMeeting = isSummarizingThisMeeting

        if case .retrying(let attempt, let maxAttempts) = summarizationPhase, isSummarizingThisMeeting {
            self.retryAttempt = (attempt, maxAttempts)
        } else {
            self.retryAttempt = nil
        }

        // A real error wins and becomes a `.failed` stage; a warning is only a
        // success-with-caveat, so it never affects the stage — it rides alongside.
        self.warning = (summarizationError == nil) ? summarizationWarning : nil

        self.stage = Self.deriveStage(
            isThisMeetingTranscribing: isThisMeetingTranscribing,
            transcriptionProgress: transcriptionProgress,
            isSummarizingThisMeeting: isSummarizingThisMeeting,
            summarizationStartedAt: summarizationStartedAt,
            summarizationError: summarizationError,
            autoExportFailure: autoExportFailure,
            meetingStatus: meetingStatus,
            hasTranscript: hasTranscript,
            hasSummary: hasSummary,
            autoSummarize: autoSummarize,
            autoExport: autoExport
        )
    }

    // MARK: - Stage derivation

    /// Priority order, most-active first:
    /// 1. Live transcription for this meeting.
    /// 2. Live summarization for this meeting.
    /// 3. A summarization error (failed summarize).
    /// 4. An auto-export failure (failed export).
    /// 5. A stale `.processing` meeting with nothing running → treated as a
    ///    transcription failure (the only path that sets `.processing`), giving
    ///    the user a Retry instead of a forever-spinner. Recovery is normally
    ///    swept at launch; this is the in-view fallback.
    /// 6. Auto-pipeline still pending (autosummarize on, no summary yet) → show
    ///    summarizing-as-next.
    /// 7. Otherwise idle/done.
    private static func deriveStage(
        isThisMeetingTranscribing: Bool,
        transcriptionProgress: Double,
        isSummarizingThisMeeting: Bool,
        summarizationStartedAt: Date?,
        summarizationError: String?,
        autoExportFailure: AutoExportFailure?,
        meetingStatus: MeetingStatus,
        hasTranscript: Bool,
        hasSummary: Bool,
        autoSummarize: Bool,
        autoExport: Bool
    ) -> PipelineStage {
        if isThisMeetingTranscribing {
            return .transcribing(progress: transcriptionProgress)
        }

        if isSummarizingThisMeeting {
            return .summarizing(startedAt: summarizationStartedAt)
        }

        if let message = summarizationError {
            return .failed(stage: .summarization, message: message)
        }

        if let failure = autoExportFailure {
            return .failed(stage: .export, message: failure.message)
        }

        // Mid-pipeline status with nothing actually running ⇒ a crashed/abandoned
        // transcription. Only transcription sets `.processing`.
        if meetingStatus == .processing {
            return .failed(
                stage: .transcription,
                message: "Transcription didn't finish — it may have been interrupted."
            )
        }

        // Auto-summarize armed but no summary yet: the next stage is summarize.
        if autoSummarize, hasTranscript, !hasSummary {
            return .summarizing(startedAt: nil)
        }

        return .done
    }

    // MARK: - Derived UI

    var isActive: Bool {
        switch stage {
        case .transcribing, .summarizing, .exporting:
            return true
        case .idle, .failed, .done:
            return false
        }
    }

    var hasError: Bool {
        if case .failed = stage { return true }
        return false
    }

    /// True when summarization is ARMED but has not actually begun: the
    /// auto-summarize-pending pseudo-stage (`.summarizing(startedAt: nil)`),
    /// derived without any live summarization running. The card renders this as a
    /// quiet "waiting" state (no spinner) so it doesn't masquerade as active work.
    /// A genuinely running summary has `startedAt != nil`, so it is NOT pending.
    var isSummarizePending: Bool {
        if case .summarizing(let startedAt) = stage {
            // Genuinely-running iff live OR a start time is set; otherwise pending.
            return startedAt == nil && !isSummarizingThisMeeting
        }
        return false
    }

    /// Index of the stage currently in flight (or failed), for chip rendering.
    private var activeKind: PipelineStageKind? {
        switch stage {
        case .transcribing: return .transcribe
        case .summarizing: return .summarize
        case .exporting: return .export
        case .failed(let failedStage, _):
            switch failedStage {
            case .transcription: return .transcribe
            case .summarization: return .summarize
            case .export: return .export
            }
        case .idle, .done:
            return nil
        }
    }

    /// Render state for a given chip. Stages before the active one read as done;
    /// the active one is active (or failed); later ones are pending.
    func chipState(for kind: PipelineStageKind) -> PipelineChipState {
        if case .done = stage { return .done }

        guard let active = activeKind else { return .pending }

        if kind.rawValue < active.rawValue { return .done }
        if kind.rawValue > active.rawValue { return .pending }

        // The active chip.
        if case .failed = stage { return .failed }
        // Auto-summarize armed but not yet started reads as pending, not active —
        // it isn't running, so it must not show the active (spinner) styling.
        if isSummarizePending { return .pending }
        return .active
    }

    /// Human-readable status line for the active row.
    var statusText: String {
        switch stage {
        case .idle, .done:
            return ""
        case .transcribing:
            return "Transcribing…"
        case .summarizing:
            if isSummarizePending {
                return "Waiting to summarize…"
            }
            if let retry = retryAttempt {
                return "Retrying (\(retry.attempt)/\(retry.maxAttempts))…"
            }
            return "Generating summary…"
        case .exporting:
            return "Exporting…"
        case .failed(let failedStage, let message):
            switch failedStage {
            case .transcription: return message
            case .summarization: return "Summary failed: \(message)"
            case .export: return "Export failed: \(message)"
            }
        }
    }
}

/// Pure, testable launch-time recovery decision for a single meeting. A meeting
/// found in `.processing` after a crash/force-quit — with no pipeline actually
/// running — would otherwise spin forever. This returns the status it should be
/// reset to. Returns nil when no change is needed.
///
/// `isAnyPipelineActive` lets the caller suppress recovery when a pipeline is
/// genuinely mid-flight at the moment of the sweep (it shouldn't be at launch,
/// but the guard makes the function safe to call any time).
enum StaleProcessingRecovery {
    /// What a stale `.processing` meeting should become. We can't model a
    /// "failed" status (the enum has no such case) without a migration, so a
    /// stale meeting is downgraded based on what content it already has:
    /// a transcript present ⇒ `.completed` (transcription clearly finished, only
    /// a later stage was interrupted); otherwise back to `.notesOnly` if it has
    /// notes, else `.completed` so the detail view's pipeline card can show the
    /// transcription-failed/retry state (driven by `meetingStatus`/content).
    static func recoveredStatus(
        currentStatus: MeetingStatus,
        hasTranscript: Bool,
        hasUserNotes: Bool,
        isAnyPipelineActive: Bool
    ) -> MeetingStatus? {
        guard currentStatus == .processing, !isAnyPipelineActive else { return nil }
        if hasTranscript {
            // Transcription completed; a later stage (summary/export) was cut off.
            // The meeting is effectively done — its detail card will offer the
            // remaining steps.
            return .completed
        }
        if hasUserNotes {
            return .notesOnly
        }
        // No transcript, no notes: leave it as completed so it stops spinning and
        // the detail view surfaces the transcription-failed/Retry affordance.
        return .completed
    }
}
