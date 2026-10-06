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
        /// Meetings whose session this sweep actually CHANGED (rendered or
        /// adopted something). A healthy paused session needs no repair and
        /// must not be counted: pausing overnight is normal use, and reporting
        /// it as "recovered" at every launch would be noise forever.
        var repairedMeetingIDs: [UUID] = []
        /// Sessions left completely alone because their raw PCM was written
        /// moments ago — something is capturing into that directory right now.
        var skippedActiveSessions = 0
        /// Segments holding raw PCM next to a WAV that already carries samples.
        /// Recovery can neither render nor delete those, so they need a human.
        var strandedSegments = 0
    }

    // MARK: - Sweep ordering

    /// The full sweep, as a sequence over three injectable steps, so the one
    /// ordering property that protects a live recording is testable:
    /// **the live-meeting set is read AFTER scanning, never before.**
    ///
    /// Reading it first leaves a window — scan classifies a directory, the user
    /// then starts recording into it, and the repair renders the in-flight PCM
    /// (whose renderer deletes the PCM it consumed) out from under the live
    /// capture. Reading it after the scan closes that window: a recording that
    /// starts later is not in `findings` at all, and one that starts in between
    /// is in the live set by the time the filter runs.
    ///
    /// Main-actor because the app's `exclusions` step must read live recording
    /// state and SwiftData; `scan` and `repair` do their filesystem work inside
    /// their own detached tasks.
    @MainActor
    static func sweep(
        scan: () async -> [RecordingSessionRecovery.Finding],
        exclusions: () async -> (live: Set<UUID>, recordingStatus: Set<UUID>),
        repair: ([RecordingSessionRecovery.Finding], Set<UUID>) async -> Outcome
    ) async -> Outcome {
        let findings = await scan()
        let sets = await exclusions()
        let filtered = excludingLive(findings: findings, liveIDs: sets.live)
        return await repair(filtered, sets.recordingStatus)
    }

    /// Drops the findings of meetings that are being captured right now. Their
    /// `.mic.pcm` / `.system.pcm` belong to the capture units, not to recovery.
    static func excludingLive(
        findings: [RecordingSessionRecovery.Finding],
        liveIDs: Set<UUID>
    ) -> [RecordingSessionRecovery.Finding] {
        findings.filter { finding in
            guard liveIDs.contains(finding.meetingID) else { return true }
            Log.recording.notice(
                "Recording recovery: skipping meeting \(finding.meetingID.uuidString, privacy: .public); it is being recorded right now"
            )
            return false
        }
    }

    // MARK: - Repair

    /// Repairs every finding. `recordingStatusMeetingIDs` are the meetings
    /// SwiftData reports as `.recording` or `.pausedRecording`, and the only
    /// input to the deletion guard. A failure on one directory is logged and
    /// skipped; the other eight still get repaired.
    ///
    /// `now` exists for the fresh-PCM guard below.
    static func repair(
        findings: [RecordingSessionRecovery.Finding],
        store: RecordingResumeSessionStore,
        recordingStatusMeetingIDs: Set<UUID>,
        now: Date = Date()
    ) -> Outcome {
        var outcome = Outcome()

        for finding in findings {
            let meetingID = finding.meetingID

            // Belt and braces behind `excludingLive`: a directory whose raw PCM
            // was written seconds ago is being captured into, whatever the app's
            // own state said a moment earlier. Touch nothing in it.
            if holdsRecentlyWrittenPCM(meetingID: meetingID, store: store, now: now) {
                outcome.skippedActiveSessions += 1
                Log.recording.notice(
                    "Recording recovery: leaving meeting \(meetingID.uuidString, privacy: .public) alone; its raw PCM was written in the last \(Int(freshPCMWindow), privacy: .public)s"
                )
                continue
            }

            switch finding {
            case .disposable:
                guard !recordingStatusMeetingIDs.contains(meetingID) else {
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
                var repaired = 0
                do {
                    repaired += try RecordingSessionRecovery.renderOrphanedTracks(
                        meetingID: meetingID,
                        store: store
                    )
                    outcome.renderedSegments += repaired
                } catch {
                    Log.recording.error(
                        "Recording recovery: could not render the orphaned tracks of meeting \(meetingID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) — audio left on disk"
                    )
                }
                // Its own `do`: a render that threw on segment 3 must not cost
                // segment 1 its manifest entry. Rendering records what it
                // renders but never adopts a WAV somebody else finalized, so
                // the same directory's unlisted WAVs still need adoption —
                // which is idempotent, so a rendered segment is not adopted
                // twice.
                repaired += adopt(meetingID: meetingID, store: store, into: &outcome)
                if repaired > 0 {
                    outcome.repairedMeetingIDs.append(meetingID)
                }

            case let .resumable(_, _, strandedPCM):
                outcome.strandedSegments += strandedPCM.count
                // A healthy paused session lands here with nothing to adopt,
                // and is deliberately not reported as repaired.
                if adopt(meetingID: meetingID, store: store, into: &outcome) > 0 {
                    outcome.repairedMeetingIDs.append(meetingID)
                }
            }
        }

        Log.recording.notice(
            """
            Recording recovery finished: \(outcome.renderedSegments, privacy: .public) segment(s) rendered, \
            \(outcome.adoptedSegments, privacy: .public) adopted, \(outcome.deletedSessions, privacy: .public) empty \
            session(s) deleted, \(outcome.keptDisposableSessions, privacy: .public) kept for an active meeting, \
            \(outcome.skippedActiveSessions, privacy: .public) skipped as live, \
            \(outcome.repairedMeetingIDs.count, privacy: .public) meeting(s) repaired, \
            \(outcome.strandedSegments, privacy: .public) stranded segment(s)
            """
        )
        return outcome
    }

    /// Adopts whatever stray WAVs the directory holds, returning how many.
    private static func adopt(
        meetingID: UUID,
        store: RecordingResumeSessionStore,
        into outcome: inout Outcome
    ) -> Int {
        do {
            let adopted = try RecordingSessionRecovery.adoptOrphanedSegments(meetingID: meetingID, store: store)
            outcome.adoptedSegments += adopted
            return adopted
        } catch {
            Log.recording.error(
                "Recording recovery: could not adopt the stray segments of meeting \(meetingID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) — audio left on disk"
            )
            return 0
        }
    }

    /// True when the directory holds raw PCM written within `freshPCMWindow` of
    /// `now` — i.e. something is recording into it. A directory we cannot list
    /// counts as active: not touching it is the answer that cannot lose audio.
    private static func holdsRecentlyWrittenPCM(
        meetingID: UUID,
        store: RecordingResumeSessionStore,
        now: Date
    ) -> Bool {
        let files: [URL]
        do {
            files = try store.sessionFiles(for: meetingID)
        } catch {
            Log.recording.notice(
                "Recording recovery: could not list the session files of meeting \(meetingID.uuidString, privacy: .public); treating it as active and leaving it alone"
            )
            return true
        }

        return files.contains { url in
            guard url.pathExtension.lowercased() == "pcm" else { return false }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                // An unreadable timestamp on a PCM file is not permission to
                // render over it.
                return true
            }
            return now.timeIntervalSince(modifiedAt) < freshPCMWindow
        }
    }

    /// How recently a raw PCM file must have been written for its directory to
    /// count as actively recording. Capture appends continuously, so seconds
    /// are enough; the cost of being wrong in the other direction is deleting
    /// live audio.
    static let freshPCMWindow: TimeInterval = 5
}

/// The one line launch recovery says to the user. Pure so its arithmetic and
/// its plurals are testable — the whole point is that it stays silent unless
/// something actually changed.
enum RecoveryToastMessage {
    /// `recoveredRecordings` is the number of DISTINCT meetings this sweep
    /// changed: a session that was repaired on disk, or a meeting whose stuck
    /// status was reconciled. Deduplicated by the caller, because one meeting
    /// can be both (the 130 MB orphaned-PCM one is exactly that) and reporting
    /// it twice would overstate the count.
    ///
    /// Returns nil when there is nothing to say, which is every launch after
    /// the first repaired one.
    static func compose(recoveredRecordings: Int, strandedSegments: Int) -> String? {
        var sentences: [String] = []

        if recoveredRecordings == 1 {
            sentences.append("1 unfinished recording was recovered — open it to Resume or Stop.")
        } else if recoveredRecordings > 1 {
            sentences.append("\(recoveredRecordings) unfinished recordings were recovered — open them to Resume or Stop.")
        }

        if strandedSegments == 1 {
            sentences.append("1 segment needs manual attention.")
        } else if strandedSegments > 1 {
            sentences.append("\(strandedSegments) segments need manual attention.")
        }

        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
