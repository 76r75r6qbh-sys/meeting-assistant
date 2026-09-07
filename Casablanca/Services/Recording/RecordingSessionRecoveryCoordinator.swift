import Foundation
import OSLog

extension RecordingSessionRecovery.Finding {
    /// The meeting the finding is about, without re-destructuring at every use.
    var meetingID: UUID {
        switch self {
        case let .disposable(meetingID):
            return meetingID
        case let .orphanedPCM(meetingID, _, _):
            return meetingID
        case let .resumable(meetingID, _, _):
            return meetingID
        }
    }
}

/// Turns `RecordingSessionRecovery` findings into actions, off the main actor.
///
/// Extracted from `AppModel` for one reason: rendering the author's real
/// 130 MB orphaned PCM pair is a synchronous ~65 MB write, and the "never
/// delete a session a meeting is still on" guard is the single most
/// consequential decision in launch recovery. Both need to be exercised
/// head-on against a temp directory, not through the app.
///
/// It performs exactly one kind of deletion — `deleteSessionIfEmpty` on a
/// `.disposable` finding, itself re-verified against the filesystem — and only
/// for a meeting no longer holding a recording status. Everything else here
/// either writes new bytes (rendering PCM into a WAV) or writes bookkeeping
/// (adopting a stray WAV into the manifest).
struct RecordingSessionRecoveryCoordinator {
    /// What one sweep did, in counts the caller can log and toast.
    struct Outcome: Equatable, Sendable {
        /// PCM pairs mixed down into `segment-NNN.wav`.
        var renderedSegments = 0
        /// Finalized WAVs written into a manifest that had forgotten them.
        var adoptedSegments = 0
        /// Empty session directories removed.
        var deletedSessions = 0
        /// Empty session directories kept because a meeting is still recording
        /// or paused on them — Resume and Stop both read that manifest.
        var keptDisposableSessions = 0
        /// Meetings whose session still holds audio after the sweep: the ones
        /// the user can now Resume or Stop.
        var resumableMeetingIDs: [UUID] = []
        /// Segments holding raw PCM next to a WAV that already carries samples.
        /// Recovery can neither render nor delete those, so they need a human.
        var strandedSegments = 0
    }

    /// Repairs every finding. `activeMeetingIDs` are the meetings SwiftData
    /// reports as `.recording` or `.pausedRecording` — a snapshot taken on the
    /// main actor before this runs off it, and the only input to the deletion
    /// guard. A failure on one directory is logged and skipped; the other eight
    /// still get repaired.
    static func repair(
        findings: [RecordingSessionRecovery.Finding],
        store: RecordingResumeSessionStore,
        activeMeetingIDs: Set<UUID>
    ) -> Outcome {
        var outcome = Outcome()

        for finding in findings {
            let meetingID = finding.meetingID
            switch finding {
            case .disposable:
                guard !activeMeetingIDs.contains(meetingID) else {
                    // Deleting the manifest of a paused meeting is how Resume
                    // starts failing with "There is no active recording to
                    // stop." Status reconciliation handles this meeting instead.
                    outcome.keptDisposableSessions += 1
                    Log.recording.notice(
                        "Recording recovery: keeping the empty session of meeting \(meetingID.uuidString, privacy: .public); a meeting is still recording or paused on it"
                    )
                    continue
                }
                do {
                    if try store.deleteSessionIfEmpty(for: meetingID) {
                        outcome.deletedSessions += 1
                    }
                } catch {
                    Log.recording.error(
                        "Recording recovery: could not delete the empty session of meeting \(meetingID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }

            case let .orphanedPCM(_, _, strandedPCM):
                outcome.strandedSegments += strandedPCM.count
                do {
                    outcome.renderedSegments += try RecordingSessionRecovery.renderOrphanedTracks(
                        meetingID: meetingID,
                        store: store
                    )
                    // Rendering records what it renders, but it never adopts a
                    // WAV somebody else finalized, so the same directory's
                    // unlisted WAVs still need adoption. Adoption is idempotent
                    // and an adopted WAV is no longer orphaned, so a rendered
                    // segment cannot be counted twice.
                    outcome.adoptedSegments += try RecordingSessionRecovery.adoptOrphanedSegments(
                        meetingID: meetingID,
                        store: store
                    )
                } catch {
                    Log.recording.error(
                        "Recording recovery: could not repair the orphaned tracks of meeting \(meetingID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) — audio left on disk"
                    )
                }
                outcome.resumableMeetingIDs.append(meetingID)

            case let .resumable(_, _, strandedPCM):
                outcome.strandedSegments += strandedPCM.count
                do {
                    outcome.adoptedSegments += try RecordingSessionRecovery.adoptOrphanedSegments(
                        meetingID: meetingID,
                        store: store
                    )
                } catch {
                    Log.recording.error(
                        "Recording recovery: could not adopt the stray segments of meeting \(meetingID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) — audio left on disk"
                    )
                }
                outcome.resumableMeetingIDs.append(meetingID)
            }
        }

        Log.recording.notice(
            """
            Recording recovery finished: \(outcome.renderedSegments, privacy: .public) segment(s) rendered, \
            \(outcome.adoptedSegments, privacy: .public) adopted, \(outcome.deletedSessions, privacy: .public) empty \
            session(s) deleted, \(outcome.keptDisposableSessions, privacy: .public) kept for an active meeting, \
            \(outcome.resumableMeetingIDs.count, privacy: .public) meeting(s) resumable, \
            \(outcome.strandedSegments, privacy: .public) stranded segment(s)
            """
        )
        return outcome
    }
}
