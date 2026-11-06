import Foundation

/// The "Regenerate summary" offer shown after a speaker is renamed or merged
/// on a meeting that already has a summary (spec A6/I2, Task 2.2).
///
/// Renames rewrite the transcript's `<Speaker>: ` prefixes, so a new summary
/// picks up the names, but the existing one still says "Speaker 1". The app
/// only offers to regenerate: the user may have accepted, edited or rejected
/// to-dos, and a regeneration replaces only pending proposals (Task 10 rules)
/// — still the user's call. Pure state, owned by `RecordedMeetingView`, which
/// is reused across meetings; offers are kept per meeting id.
struct SummaryRegenerationOffer: Equatable {
    private var offeredMeetingIDs: Set<UUID> = []

    /// A speaker of `meeting` was renamed or merged. Offers when the meeting
    /// has a summary, or one is being generated for it right now (that run
    /// read the transcript before the rename, so it lands with the old names).
    mutating func speakersChanged(on meeting: Meeting, isSummarizingThisMeeting: Bool) {
        guard Self.hasSummary(meeting) || isSummarizingThisMeeting else { return }
        offeredMeetingIDs.insert(meeting.id)
    }

    /// Whether the banner shows for `meeting`: offered, the meeting has a
    /// summary to replace, and no summary is running (the service runs one at
    /// a time and ignores a second request).
    func offerRegenerateSummary(for meeting: Meeting, isSummarizing: Bool) -> Bool {
        offeredMeetingIDs.contains(meeting.id) && Self.hasSummary(meeting) && !isSummarizing
    }

    /// The user closed the banner without regenerating.
    mutating func dismiss(_ meeting: Meeting) {
        offeredMeetingIDs.remove(meeting.id)
    }

    /// The user chose "Regenerate summary": `start` gets the meeting's
    /// explicit template (`summaryTemplateID`, nil = auto-select) and the
    /// offer clears.
    mutating func regenerate(_ meeting: Meeting, start: (_ templateID: String?) -> Void) {
        offeredMeetingIDs.remove(meeting.id)
        start(meeting.summaryTemplateID)
    }

    /// A new summary of the meeting started by any route (this banner, the
    /// template menu, a retry): it reads the renamed transcript, so the offer
    /// is answered.
    mutating func summaryStarted(for meetingID: UUID) {
        offeredMeetingIDs.remove(meetingID)
    }

    private static func hasSummary(_ meeting: Meeting) -> Bool {
        meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
