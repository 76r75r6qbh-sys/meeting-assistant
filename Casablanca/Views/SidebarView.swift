import SwiftUI
import SwiftData

struct SidebarView: View {
    @Bindable var viewModel: MeetingListViewModel
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedMeeting },
            set: { viewModel.selectedMeeting = $0 }
        )) {
            // Dashboard link
            Section {
                Button {
                    viewModel.selectedMeeting = nil
                } label: {
                    Label("Dashboard", systemImage: "calendar")
                }
                .foregroundStyle(viewModel.selectedMeeting == nil ? Color.accentPrimary : Color.textSecondary)
            }

            // Recent meetings with notes/recordings
            if !recentMeetings.isEmpty {
                Section("Recent") {
                    ForEach(recentMeetings) { meeting in
                        Button {
                            viewModel.selectedMeeting = meeting
                        } label: {
                            SidebarMeetingRow(meeting: meeting)
                        }
                        .foregroundStyle(viewModel.selectedMeeting?.id == meeting.id ? Color.accentPrimary : Color.textPrimary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var recentMeetings: [Meeting] {
        meetings.filter { $0.status != .upcoming }
    }
}

struct SidebarMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            statusIcon
                .frame(width: 14)

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)

                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Spacer()
        }
        .frame(height: CasaLayout.sidebarItemHeight)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch meeting.status {
        case .recording:
            Image(systemName: "record.circle")
                .font(.caption)
                .foregroundStyle(Color.stateRecording)
        case .processing:
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.stateProcessing)
        case .notesOnly:
            Image(systemName: "pencil.line")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.accentSuccess)
        case .upcoming:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(Color.stateIdle)
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: meeting.date)
    }
}
