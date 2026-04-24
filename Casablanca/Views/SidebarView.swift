import SwiftUI
import SwiftData

enum SidebarMeetingSection: Hashable {
    case upcoming
    case recent
}

enum SidebarMeetingRowAction: Hashable {
    case deleteMeeting
}

struct SidebarMeetingRowActions {
    let section: SidebarMeetingSection

    var contextMenuActions: [SidebarMeetingRowAction] {
        section == .upcoming ? [] : [.deleteMeeting]
    }
}

struct SidebarView: View {
    @Bindable var viewModel: MeetingListViewModel
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(filter: #Predicate<TodoItem> { !$0.isCompleted }) private var openTodos: [TodoItem]
    // @State drives List(selection:) directly — avoids @Bindable+@Observable binding issues
    @State private var selection: SidebarDestination? = .dashboard
    @State private var meetingPendingDeletion: Meeting?
    @State private var deletionErrorMessage: String?

    private var openTodoCount: Int { openTodos.count }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Dashboard", systemImage: "calendar")
                    .tag(SidebarDestination.dashboard)
            }

            Section {
                Label("To-Dos", systemImage: "checklist")
                    .badge(openTodoCount)
                    .tag(SidebarDestination.todos)
            }

            if !upcomingMeetings.isEmpty {
                Section("Upcoming") {
                    ForEach(upcomingMeetings) { meeting in
                        SidebarMeetingRow(
                            meeting: meeting,
                            section: .upcoming,
                            onDeleteRequest: {
                                meetingPendingDeletion = meeting
                            }
                        )
                        .tag(SidebarDestination.meeting(meeting.id))
                    }
                }
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
                        SidebarMeetingRow(
                            meeting: meeting,
                            section: .recent,
                            onDeleteRequest: {
                                meetingPendingDeletion = meeting
                            }
                        )
                            .tag(SidebarDestination.meeting(meeting.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $viewModel.meetingSearchText, placement: .sidebar)
        .confirmationDialog(
            meetingPendingDeletion.map { "Delete \"\($0.title)\"?" } ?? "Delete Meeting?",
            isPresented: Binding(
                get: { meetingPendingDeletion != nil },
                set: { newValue in
                    if !newValue {
                        meetingPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                confirmDeleteMeeting()
            }
            Button("Cancel", role: .cancel) {
                meetingPendingDeletion = nil
            }
        } message: {
            Text("This removes the meeting, notes, transcript, summary, to-dos, and saved recording from Casablanca.")
        }
        .alert("Unable to Delete Meeting", isPresented: deletionErrorBinding) {
            Button("OK", role: .cancel) {
                deletionErrorMessage = nil
            }
        } message: {
            Text(deletionErrorMessage ?? "Unknown error")
        }
        // Sync @State → ViewModel when user taps a sidebar row
        .onChange(of: selection) { _, new in
            viewModel.sidebarSelection = new
        }
        // Sync ViewModel → @State when code sets selection (e.g. beginRecording)
        .onChange(of: viewModel.sidebarSelection) { _, new in
            if selection != new { selection = new }
        }
    }

    private var recentMeetings: [Meeting] {
        viewModel.filteredRecentMeetings(from: meetings)
    }

    private var upcomingMeetings: [Meeting] {
        viewModel.filteredUpcomingMeetings(from: meetings)
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    deletionErrorMessage = nil
                }
            }
        )
    }

    private func confirmDeleteMeeting() {
        guard let meeting = meetingPendingDeletion else { return }

        meetingPendingDeletion = nil

        do {
            try viewModel.deleteMeeting(meeting)
            selection = viewModel.sidebarSelection
        } catch {
            deletionErrorMessage = error.localizedDescription
        }
    }
}

struct SidebarMeetingRow: View {
    let meeting: Meeting
    let section: SidebarMeetingSection
    let onDeleteRequest: () -> Void

    private var actions: SidebarMeetingRowActions {
        SidebarMeetingRowActions(section: section)
    }

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
        .contextMenu {
            ForEach(actions.contextMenuActions, id: \.self) { action in
                switch action {
                case .deleteMeeting:
                    Button("Delete Meeting…", role: .destructive, action: onDeleteRequest)
                }
            }
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
        case .pausedRecording:
            Image(systemName: "pause.circle")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .foregroundStyle(Color.stateIdle)
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
        case .pausedRecording: return "Paused recording"
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
