import Foundation
import Observation

/// A failed automatic export, captured for surfacing in the pipeline-status UI.
/// Auto-export is fire-and-forget (it runs off the back of a save), so failures
/// previously only landed in the log; this lets a specific meeting's detail view
/// show the failure with a Retry affordance.
struct AutoExportFailure: Equatable {
    let meetingID: UUID
    /// Display name of the destination that failed (e.g. "Obsidian", "Apple Notes").
    let destination: String
    let message: String
}

/// App-wide sink for automatic-export outcomes. Held on `AppModel` and passed
/// into `ExportService.exportAutomaticallyIfEnabled` so a swallowed failure
/// becomes visible state the UI can react to (and retry/dismiss).
@MainActor
@Observable
final class ExportStatusCenter {
    /// The most recent auto-export failure, or nil once cleared/succeeded.
    private(set) var lastAutoExportFailure: AutoExportFailure?

    func reportFailure(meetingID: UUID, destination: String, message: String) {
        lastAutoExportFailure = AutoExportFailure(
            meetingID: meetingID,
            destination: destination,
            message: message
        )
    }

    /// Clears the failure for a specific meeting (no-op if the stored failure is
    /// for a different meeting), so dismissing one meeting's error doesn't hide
    /// another's.
    func clearFailure(for meetingID: UUID) {
        if lastAutoExportFailure?.meetingID == meetingID {
            lastAutoExportFailure = nil
        }
    }

    /// The auto-export failure for a specific meeting, or nil.
    func failure(for meetingID: UUID) -> AutoExportFailure? {
        guard let failure = lastAutoExportFailure, failure.meetingID == meetingID else { return nil }
        return failure
    }
}
