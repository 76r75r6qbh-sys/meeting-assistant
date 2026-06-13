import SwiftUI

/// Calm in-content meeting header for the notes-taking state, mirroring the
/// prep/detail headers: title + meta line (date · time · participant count) +
/// participant avatars. Placed as a sibling above the notes area so the editor's
/// container is never restructured.
struct MeetingNotesHeader: View {
    @Bindable var meeting: Meeting

    var body: some View {
        HStack(alignment: .top, spacing: CasaSpace.md) {
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(meeting.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer(minLength: CasaSpace.md)

            ParticipantAvatars(names: meeting.participants)
        }
        .padding(.horizontal, CasaSpace.xl)
        .padding(.vertical, CasaSpace.lg)
    }

    private var metaLine: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM"
        let day = dateFormatter.string(from: meeting.date)
        let count = meeting.participants.count
        guard count > 0 else {
            return "\(day) · \(meeting.formattedTime)"
        }
        let participantLabel = count == 1 ? "1 participant" : "\(count) participants"
        return "\(day) · \(meeting.formattedTime) · \(participantLabel)"
    }
}
