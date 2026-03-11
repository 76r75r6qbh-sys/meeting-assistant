import SwiftUI
import SwiftData

struct SidebarView: View {
    @Bindable var viewModel: MeetingListViewModel
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]

    var body: some View {
        List(selection: $viewModel.sidebarSelection) {
            // Dashboard link
            Section {
                Label("Dashboard", systemImage: "calendar")
                    .tag(SidebarDestination.dashboard)
            }

            // Recent meetings with notes/recordings
            if !recentMeetings.isEmpty {
                Section("Recent") {
                    ForEach(recentMeetings) { meeting in
                        SidebarMeetingRow(meeting: meeting)
                            .tag(SidebarDestination.meeting(meeting.id))
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meeting.title), \(statusAccessibilityLabel), \(formattedDate)")
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

    private var statusAccessibilityLabel: String {
        switch meeting.status {
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .notesOnly: return "Notes only"
        case .completed: return "Completed"
        case .upcoming: return "Upcoming"
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: meeting.date)
    }
}

// MARK: - Sidebar Navigation Destination

enum SidebarDestination: Hashable {
    case dashboard
    case meeting(UUID)
}
