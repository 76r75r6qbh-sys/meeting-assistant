import SwiftUI
import SwiftData

struct SidebarView: View {
    @Bindable var viewModel: MeetingListViewModel
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(filter: #Predicate<TodoItem> { !$0.isCompleted }) private var openTodos: [TodoItem]

    private var openTodoCount: Int { openTodos.count }

    var body: some View {
        List(selection: $viewModel.sidebarSelection) {
            Section {
                Label("Dashboard", systemImage: "calendar")
                    .tag(SidebarDestination.dashboard)
            }

            Section {
                Label {
                    Text("To-Dos")
                } icon: {
                    Image(systemName: "checklist")
                }
                .tag(SidebarDestination.todos)
                .badge(openTodoCount)
            }

            Section("Recent") {
                if recentMeetings.isEmpty {
                    Text(
                        viewModel.meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No recent meetings yet."
                        : "No matching meetings."
                    )
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(recentMeetings) { meeting in
                        SidebarMeetingRow(meeting: meeting)
                            .tag(SidebarDestination.meeting(meeting.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $viewModel.meetingSearchText, placement: .sidebar)
    }

    private var recentMeetings: [Meeting] {
        viewModel.filteredRecentMeetings(from: meetings)
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
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .foregroundStyle(Color.stateRecording)
        case .processing:
            Image(systemName: "sparkles")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .foregroundStyle(Color.stateProcessing)
        case .notesOnly:
            Image(systemName: "pencil.line")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .foregroundStyle(Color.textSecondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .foregroundStyle(Color.accentSuccess)
        case .upcoming:
            Image(systemName: "circle")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
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
    case todos
    case meeting(UUID)
}
