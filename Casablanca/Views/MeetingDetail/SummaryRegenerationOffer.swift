import SwiftUI

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

/// The offer's banner: small and non-modal, shown above the detail tabs so it
/// is visible on the Transcript tab (where speakers change) and on Summary.
/// Neutral wording: "This is me" also changes speakers without renaming.
/// Side by side when there is room, stacked in a narrow column.
struct SummaryRegenerationBanner: View {
    var canRegenerate: Bool = true
    let onRegenerate: () -> Void
    let onDismiss: () -> Void

    static let message = "Speakers changed — regenerate the summary?"
    static let buttonTitle = "Regenerate summary"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: CasaSpace.sm) {
                icon
                text
                regenerateButton
                dismissButton
            }
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                    icon
                    text
                    dismissButton
                }
                regenerateButton
            }
        }
        .padding(CasaSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentSecondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: "person.2.wave.2")
            .foregroundStyle(Color.accentSecondary)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
    }

    private var text: some View {
        Text(Self.message)
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Accepted and rejected to-dos are kept.")
    }

    private var regenerateButton: some View {
        Button(Self.buttonTitle, action: onRegenerate)
            .buttonStyle(GhostButtonStyle())
            .font(.caption)
            .fixedSize()
            .disabled(!canRegenerate)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss regenerate summary offer")
    }
}
