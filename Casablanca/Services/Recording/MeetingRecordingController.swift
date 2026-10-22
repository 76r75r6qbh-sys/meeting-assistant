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
        case failed
    }

    private let recordingService: AudioRecordingService
    private(set) var startingMeetingIDs: Set<UUID> = []
    private(set) var stoppingMeetingIDs: Set<UUID> = []

    init(recordingService: AudioRecordingService) {
        self.recordingService = recordingService
    }

    var isStartInFlight: Bool { !startingMeetingIDs.isEmpty }

    /// Starts capture for `meeting`. Reserves the meeting synchronously, before
    /// the first suspension point, so a caller that invokes this in the same
    /// main-actor turn as it flips the meeting to `.recording` always wins over
    /// the editor view's `.task` that flip triggers.
    func startRecording(for meeting: Meeting, save: () -> Void) async -> StartOutcome {
        guard !startingMeetingIDs.contains(meeting.id) else { return .alreadyStarting }
        if recordingService.isRecording && recordingService.activeMeetingID == meeting.id {
            return .alreadyRecording
        }

        startingMeetingIDs.insert(meeting.id)
        defer { startingMeetingIDs.remove(meeting.id) }

        do {
            try await recordingService.startRecording(for: meeting)
            meeting.status = .recording
            save()
            return .started
        } catch {
            // The service has set `errorMessage`; the editor surfaces it as the
            // "Recording Error" alert (with Retry) whenever it is on screen.
            meeting.status = .notesOnly
            save()
            return .failed
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
            return result
        } catch {
            recordingService.setErrorMessage(error.localizedDescription)
            meeting.status = recordingService.hasResumableSession(for: meeting.id) ? .pausedRecording : .notesOnly
            save()
            throw error
        }
    }
}
