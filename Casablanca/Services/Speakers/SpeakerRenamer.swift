import Foundation

/// Names a speaker in one meeting.
///
/// A rename only rewrites the `<Speaker>: ` line prefixes in `transcript` (and
/// in `rawTranscript` when there is one) through
/// `TranscriptLineFormat.renameSpeaker`. It never re-renders the transcript
/// from the segments: the segments hold Whisper's deterministic text, while
/// `transcript` holds the LLM-corrected and hand-edited text the user sees.
@MainActor
enum SpeakerRenamer {
    enum RenameError: Error, Equatable {
        case emptyName, unknownSpeaker
        /// Another speaker already has this name and it is not a merge target
        /// (only a confirmed name or the user is). Two speakers must never
        /// share a display name: their prefixes could not be told apart.
        case nameInUse
    }

    /// The name as stored and written as a prefix: trimmed, `:` `[` `]`
    /// replaced, whitespace collapsed, at most 40 characters. Stored sanitized
    /// so `TranscriptLineFormat.parse(_:knownSpeakers:)` keeps matching it.
    nonisolated static func sanitize(_ name: String) -> String {
        TranscriptLineFormat.sanitizedSpeakerName(name)
    }

    /// Renames `speakerID` to `name` and marks the name confirmed.
    ///
    /// When another speaker already has that name (case-insensitively) and
    /// that name is a person's (confirmed, or the user's), the two are the
    /// same person: this speaker's segments move to the other id, its
    /// `SpeakerInfo` is dropped, its prefixes take the other speaker's
    /// spelling, and the result is `true`. Any other name clash (another
    /// speaker's placeholder label, "Speaker 2") throws `.nameInUse` and
    /// changes nothing.
    ///
    /// `store` is the meeting's sidecar store. When the merged speakers were
    /// heard on different tracks, the moved segments' own source is kept there
    /// (`segmentSources`, the sidecar is created if needed), so their samples
    /// still play from the right track — whoever calls the merge.
    @discardableResult
    static func rename(
        speakerID: String,
        to name: String,
        in meeting: Meeting,
        store: SpeakerAnalysisStore
    ) throws -> Bool {
        let newName = sanitize(name)
        guard !newName.isEmpty else { throw RenameError.emptyName }
        var speakers = meeting.speakers
        guard let index = speakers.firstIndex(where: { $0.id == speakerID }) else {
            throw RenameError.unknownSpeaker
        }
        let oldName = sanitize(speakers[index].displayName)

        if let targetIndex = speakers.firstIndex(where: {
            $0.id != speakerID && sanitize($0.displayName).caseInsensitiveCompare(newName) == .orderedSame
        }) {
            let target = speakers[targetIndex]
            guard target.nameConfirmed || target.isUser else { throw RenameError.nameInUse }
            if speakers[index].source != target.source {
                recordSources(
                    of: meeting.speakerSegments.filter { $0.speakerID == speakerID },
                    source: speakers[index].source,
                    meetingID: meeting.id,
                    store: store
                )
            }
            rewritePrefixes(in: meeting, from: oldName, to: sanitize(target.displayName))
            meeting.speakerSegments = meeting.speakerSegments.map { segment in
                guard segment.speakerID == speakerID else { return segment }
                var moved = segment
                moved.speakerID = target.id
                return moved
            }
            speakers[targetIndex].nameConfirmed = true
            // Either half marked as the user keeps the merged speaker the user.
            speakers[targetIndex].isUser = target.isUser || speakers[index].isUser
            speakers.remove(at: index)
            meeting.speakers = speakers
            return true
        }

        rewritePrefixes(in: meeting, from: oldName, to: newName)
        speakers[index].displayName = newName
        speakers[index].nameConfirmed = true
        meeting.speakers = speakers
        return false
    }

    /// Marks `speakerID` as the user (in-room meetings, where every cluster is
    /// a room speaker), or clears it. At most one speaker is the user: marking
    /// one clears the flag on every other speaker. Changes no text.
    static func setIsUser(_ isUser: Bool, speakerID: String, in meeting: Meeting) throws {
        var speakers = meeting.speakers
        guard speakers.contains(where: { $0.id == speakerID }) else { throw RenameError.unknownSpeaker }
        for index in speakers.indices {
            if speakers[index].id == speakerID {
                speakers[index].isUser = isUser
            } else if isUser {
                speakers[index].isUser = false
            }
        }
        meeting.speakers = speakers
    }

    /// Adds `source` for each moved segment that has no recorded source yet
    /// (an earlier merge already knows the true one). Best-effort: a sidecar
    /// that cannot be written only costs the right sample track.
    private static func recordSources(
        of segments: [SpeakerSegment],
        source: SpeakerSource,
        meetingID: UUID,
        store: SpeakerAnalysisStore
    ) {
        guard !segments.isEmpty else { return }
        var record = store.load(meetingID)
            ?? SpeakerAnalysisRecord(meetingID: meetingID, diarization: .notRun, suggestions: [])
        var sources = record.segmentSources ?? [:]
        for segment in segments {
            let key = SpeakerClipSelector.segmentKey(segment)
            if sources[key] == nil { sources[key] = source }
        }
        record.segmentSources = sources
        do {
            try store.save(record)
        } catch {
            Log.transcription.error(
                "Could not record merged segment sources: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func rewritePrefixes(in meeting: Meeting, from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        if let transcript = meeting.transcript {
            meeting.transcript = TranscriptLineFormat.renameSpeaker(in: transcript, from: oldName, to: newName)
        }
        if let raw = meeting.rawTranscript {
            meeting.rawTranscript = TranscriptLineFormat.renameSpeaker(in: raw, from: oldName, to: newName)
        }
    }
}
