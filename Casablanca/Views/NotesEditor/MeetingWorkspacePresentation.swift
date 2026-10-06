import Foundation

struct MeetingWorkspacePresentation {
    let meeting: Meeting
    let activeMeetingID: UUID?
    let isRecording: Bool
    let isPreparing: Bool
    let isFinalizing: Bool
    let prefersRecordingFocusMode: Bool

    var isActiveMeeting: Bool {
        activeMeetingID == meeting.id
    }

    var showsRecordingChrome: Bool {
        meeting.status == .recording || meeting.status == .pausedRecording
    }

    var showsFocusedRecordingControls: Bool {
        showsRecordingChrome && prefersRecordingFocusMode
    }

    /// Focus mode is a pure view state: it can be active whether or not a
    /// recording is in progress. It hides chrome (prep, to-dos, the device
    /// chip, the recording bar) and centers the notes for distraction-free
    /// writing. Recording + autosave keep running underneath.
    var isFocusModeActive: Bool {
        prefersRecordingFocusMode && !isFinalizing
    }

    /// In focus mode, while recording, the live state collapses to a single
    /// unobtrusive pill (pulsing dot + timer) that still exposes pause/stop.
    var showsFocusRecordingPill: Bool {
        isFocusModeActive && showsRecordingChrome
    }

    var showsExpandedRecordingChrome: Bool {
        showsRecordingChrome && !showsFocusedRecordingControls
    }

    /// The calm in-content meeting header (title + meta + avatars) sits above
    /// the notes area in the notes-taking state only — not while recording (the
    /// recording bar serves that role) and not in focus mode (distraction-free).
    var showsNotesHeader: Bool {
        !showsRecordingChrome && !isFocusModeActive && !isFinalizing
    }

    var showsCompactRecordingControls: Bool {
        showsFocusedRecordingControls
    }

    var showsStartRecordingButton: Bool {
        meeting.status == .notesOnly || meeting.status == .upcoming
    }

    var showsPauseRecordingButton: Bool {
        meeting.status == .recording && isActiveMeeting && isRecording && !isFinalizing
    }

    var showsResumeRecordingButton: Bool {
        meeting.status == .pausedRecording && !isFinalizing
    }

    var showsStopRecordingButton: Bool {
        showsRecordingChrome && !isFinalizing
    }

    var backButtonDisabled: Bool {
        isFinalizing || (meeting.status == .recording && isActiveMeeting && isRecording)
    }

    var showsBlockingOverlay: Bool {
        isFinalizing
    }

    var blockingOverlayTitle: String? {
        guard isFinalizing else { return nil }
        return "Finalizing recording…"
    }

    var stateLabel: String {
        if isFinalizing { return "Finalizing" }
        if isPreparing { return "Preparing" }
        if meeting.status == .pausedRecording { return "Paused" }
        return "Recording"
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case prep = "Prep"
    case todos = "To-Dos"
    var id: String { rawValue }
}

struct MeetingPrepPresentation: Equatable {
    let markdown: String?
    let isExpanded: Bool

    var hasPrep: Bool {
        !(markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var showsPrepPane: Bool {
        hasPrep && isExpanded
    }

    var showsShowPrepButton: Bool {
        hasPrep && !isExpanded
    }

    var markdownText: String {
        markdown ?? ""
    }
}

struct FreeformWorkspacePresentation: Equatable {
    let showsRecordingChrome: Bool

    var showsTodosArea: Bool {
        true
    }
}

struct AutoPauseIndicatorPresentation {
    let records: [RecordingInterruptionCoordinator.InterruptionRecord]
    let referenceDate: Date

    private static let visibilityWindow: TimeInterval = 300

    var shouldShow: Bool {
        guard let latest = records.last, let endedAt = latest.endedAt else { return false }
        return referenceDate.timeIntervalSince(endedAt) < Self.visibilityWindow
    }

    var summary: String {
        guard let latest = records.last, let endedAt = latest.endedAt else { return "" }
        let duration = Int(endedAt.timeIntervalSince(latest.startedAt).rounded())
        let timeOfDay = formattedTime(latest.startedAt)
        let suffix = latest.resumedAutomatically ? "recording resumed." : "tap Resume to continue."
        let cause: String
        switch latest.reason {
        case .screenLock: cause = "Auto-paused at \(timeOfDay) for \(duration)s"
        case .systemSleep: cause = "Auto-paused at \(timeOfDay) (sleep, \(duration)s)"
        case .audioDeviceLost: cause = "Auto-paused at \(timeOfDay) — microphone disconnected"
        case .displayUnavailable: cause = "Auto-paused at \(timeOfDay) — no display for system audio"
        case .streamFailure: cause = "Auto-paused at \(timeOfDay) — recording stream stopped"
        }
        return "\(cause) — \(suffix)"
    }

    func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
