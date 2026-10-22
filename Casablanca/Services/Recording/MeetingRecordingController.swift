import Foundation
import Observation

/// Starts and stops a meeting's capture and keeps the meeting's status in step,
/// independent of any view.
///
/// Until Teams auto-record, capture only ever started from `NotesEditorView`'s
/// `.task` — so a meeting flipped to `.recording` with no main window open (the
/// menu-bar-only case) never captured a byte. Both the editor and the Teams
/// coordinator now go through here. It also closes the race the two would
/// otherwise have: `AudioRecordingService.startRecording` only refuses once a
/// session is *published*, so two starts for the same meeting during the
/// seconds of `isPreparing` would both build a session. The in-flight sets
/// below make the second caller back off instead.
@MainActor
@Observable
final class MeetingRecordingController {
    enum StartOutcome: Equatable {
        case started
        /// The service is already capturing this meeting.
        case alreadyRecording
        /// Another caller's start for this meeting is in flight; it owns the
        /// outcome, including the status flip.
        case alreadyStarting
        /// This meeting's Stop is in flight (finalizing or merging). The user
        /// stopped it: a start must neither reopen it nor touch its status.
        case refusedWhileStopping
        case failed
    }

    private let recordingService: AudioRecordingService
    private(set) var startingMeetingIDs: Set<UUID> = []
    private(set) var stoppingMeetingIDs: Set<UUID> = []
    /// Why the most recent `.failed` start failed. Scoped to this controller's
    /// own start, unlike the service's `errorMessage`, which a refusal thrown
    /// before the service clears it leaves holding an older error.
    private(set) var lastStartFailureMessage: String?
    /// Called once per successful stop, whichever path stopped it (editor,
    /// notification, Teams auto-stop), with the stopped meeting's id. The app
    /// clears the interruption coordinator's bookkeeping here.
    var onMeetingStopped: ((UUID) -> Void)?
    /// How long a start waits for a Stop that is finalizing another meeting's
    /// live segment to release the capture, polling every `releasePollInterval`.
    private let captureReleaseTimeout: Duration
    private let releasePollInterval: Duration

    init(
        recordingService: AudioRecordingService,
        captureReleaseTimeout: Duration = .seconds(15),
        releasePollInterval: Duration = .milliseconds(50)
    ) {
        self.recordingService = recordingService
        self.captureReleaseTimeout = captureReleaseTimeout
        self.releasePollInterval = releasePollInterval
    }

    var isStartInFlight: Bool { !startingMeetingIDs.isEmpty }

    func isStopInFlight(for meetingID: UUID) -> Bool { stoppingMeetingIDs.contains(meetingID) }

    /// Whether a new recording would have to wait or be refused: something is
    /// capturing, preparing or starting. A capture whose Stop is already in
    /// flight does not count — it is going away, and a start waits for it to
    /// release the session (see `startRecording`).
    var isBusyForNewRecording: Bool {
        TeamsAutoRecordPolicy.isRecordingBusy(
            isRecording: recordingService.isRecording,
            isPreparing: recordingService.isPreparing,
            isStartInFlight: isStartInFlight,
            activeMeetingID: recordingService.activeMeetingID,
            stoppingMeetingIDs: stoppingMeetingIDs
        )
    }

    /// Starts capture for `meeting`. Reserves the meeting synchronously, before
    /// the first suspension point, so a caller that invokes this in the same
    /// main-actor turn as it flips the meeting to `.recording` always wins over
    /// the editor view's `.task` that flip triggers.
    func startRecording(for meeting: Meeting, save: () -> Void) async -> StartOutcome {
        guard !startingMeetingIDs.contains(meeting.id) else { return .alreadyStarting }
        guard !stoppingMeetingIDs.contains(meeting.id) else {
            Log.recording.notice(
                "Not starting meeting \(meeting.id.uuidString, privacy: .public): its Stop is in flight"
            )
            return .refusedWhileStopping
        }
        if recordingService.isRecording && recordingService.activeMeetingID == meeting.id {
            return .alreadyRecording
        }

        startingMeetingIDs.insert(meeting.id)
        defer { startingMeetingIDs.remove(meeting.id) }
        lastStartFailureMessage = nil

        // Another meeting's Stop is finalizing its live segment: the session
        // stays published until that finalize returns, so the service would
        // refuse with `.activeRecordingExists`. It is going away — wait for it.
        await waitForStoppingCaptureToRelease()

        do {
            try await recordingService.startRecording(for: meeting)
            meeting.status = .recording
            save()
            return .started
        } catch {
            // Refused because the user stopped this meeting while the start was
            // in flight (`refuseWhileStopping` throws a cancellation): its Stop
            // owns the status. `.notesOnly` here would strand a meeting that is
            // still merging, or overwrite the merge's `.processing`.
            if error is CancellationError || stoppingMeetingIDs.contains(meeting.id) {
                return .refusedWhileStopping
            }
            lastStartFailureMessage = error.localizedDescription
            // The service has set `errorMessage`; the editor surfaces it as the
            // "Recording Error" alert (with Retry) whenever it is on screen.
            meeting.status = .notesOnly
            save()
            return .failed
        }
    }

    private func waitForStoppingCaptureToRelease() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: captureReleaseTimeout)
        while recordingService.isRecording,
              let active = recordingService.activeMeetingID,
              stoppingMeetingIDs.contains(active),
              clock.now < deadline,
              !Task.isCancelled {
            try? await Task.sleep(for: releasePollInterval)
        }
    }

    /// Stops capture, merges the segments and moves the meeting to
    /// `.processing` — the same steps the editor's Stop button always took.
    /// Returns `nil` without doing anything when another stop for this meeting
    /// is already in flight. On failure the error is surfaced through the
    /// service's `errorMessage`, the meeting falls back to paused (audio still
    /// resumable) or notes-only, and the error is rethrown.
    func stopRecording(for meeting: Meeting, save: () -> Void) async throws -> RecordingResult? {
        guard !stoppingMeetingIDs.contains(meeting.id) else { return nil }
        stoppingMeetingIDs.insert(meeting.id)
        defer { stoppingMeetingIDs.remove(meeting.id) }

        do {
            let result = try await recordingService.stopRecording(for: meeting)
            meeting.recordingFileURL = result.outputURL.path
            meeting.recordingDuration = result.duration
            meeting.status = .processing
            save()
            onMeetingStopped?(meeting.id)
            return result
        } catch {
            recordingService.setErrorMessage(error.localizedDescription)
            meeting.status = recordingService.hasResumableSession(for: meeting.id) ? .pausedRecording : .notesOnly
            save()
            throw error
        }
    }
}
