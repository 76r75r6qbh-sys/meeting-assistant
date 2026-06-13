import SwiftUI
import SwiftData

enum SidebarMeetingSection: Hashable {
    case upcoming
    case recent
}

enum SidebarMeetingRowAction: Hashable {
    case prepare
    case deleteMeeting
}

struct SidebarMeetingRowActions {
    let section: SidebarMeetingSection

    var contextMenuActions: [SidebarMeetingRowAction] {
        section == .upcoming ? [.prepare] : [.deleteMeeting]
    }
}

struct SidebarView: View {
    @Bindable var viewModel: MeetingListViewModel
    /// Windowed, partial-fetch provider of recent meetings (Phase 3b). Replaces
    /// the old `@Query` that hydrated every meeting (transcripts included).
    var meetingsProvider: SidebarMeetingsProvider
    @Environment(AppModel.self) private var appModel
    @Query(filter: #Predicate<TodoItem> { !$0.isCompleted }) private var openTodos: [TodoItem]
    // @State drives List(selection:) directly — avoids @Bindable+@Observable binding issues
    @State private var selection: SidebarDestination? = .dashboard
    @State private var meetingPendingDeletion: Meeting?
    @State private var deletionErrorMessage: String?

    private var openTodoCount: Int { openTodos.count }

    var body: some View {
        // Read in this view's tracked context so the badge updates reactively
        // when the watcher/bootstrap mutates the queue.
        let pendingCount = appModel.actionQueueModel.pendingCount
        return List(selection: $selection) {
            Section {
                Label("Dashboard", systemImage: "calendar")
                    .tag(SidebarDestination.dashboard)
            }

            Section {
                Label("To-Dos", systemImage: "checklist")
                    .badge(openTodoCount)
                    .tag(SidebarDestination.todos)
            }

            Section {
                Label("Approvals", systemImage: "tray.full")
                    .badge(pendingCount)
                    .tag(SidebarDestination.actionQueue)
            }

            if !upcomingMeetings.isEmpty {
                Section("Upcoming") {
                    ForEach(upcomingMeetings) { meeting in
                        SidebarMeetingRow(
                            meeting: meeting,
                            section: .upcoming,
                            pipeline: pipelinePresentation(for: meeting),
                            onPrepareRequest: {
                                viewModel.beginPrepare(for: meeting)
                            },
                            onDeleteRequest: {
                                meetingPendingDeletion = meeting
                            }
                        )
                        .tag(SidebarDestination.meeting(meeting.id))
                    }
                }
            }

            if recentMeetings.isEmpty {
                Section("Recent") {
                    Text(
                        viewModel.meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No recent meetings yet."
                        : "No matching meetings."
                    )
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(bucketedRecentMeetings, id: \.bucket) { pair in
                    Section(pair.bucket.title) {
                        ForEach(pair.meetings) { meeting in
                            SidebarMeetingRow(
                                meeting: meeting,
                                section: .recent,
                                pipeline: pipelinePresentation(for: meeting),
                                onDeleteRequest: {
                                    meetingPendingDeletion = meeting
                                }
                            )
                                .tag(SidebarDestination.meeting(meeting.id))
                        }
                    }
                }

                if meetingsProvider.hasMore {
                    Section {
                        Button {
                            meetingsProvider.loadMore()
                        } label: {
                            Label("Show earlier meetings", systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Push the sidebar's title search down into the provider's SQLite fetch.
        .onChange(of: viewModel.meetingSearchText) { _, new in
            meetingsProvider.searchText = new
        }
        .onAppear {
            meetingsProvider.searchText = viewModel.meetingSearchText
        }
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

    /// Pure pipeline presentation for a row's compact processing indicator,
    /// derived from the live services + this meeting's state.
    private func pipelinePresentation(for meeting: Meeting) -> MeetingPipelinePresentation {
        let isSummarizingThis = appModel.summarizationService.summarizingMeetingID == meeting.id
        return MeetingPipelinePresentation(
            isThisMeetingTranscribing: appModel.transcriptionService.isTranscribing && meeting.status == .processing,
            transcriptionProgress: appModel.transcriptionService.progress,
            isSummarizingThisMeeting: isSummarizingThis,
            summarizationPhase: appModel.summarizationService.phase,
            summarizationStartedAt: appModel.summarizationService.summarizationStartedAt,
            // Errors (summary/export) are surfaced in the detail view, not the
            // sidebar row, so the row only reflects active/stale state.
            summarizationError: nil,
            autoExportFailure: nil,
            meetingStatus: meeting.status,
            hasTranscript: meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasSummary: meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            autoSummarize: false,
            autoExport: false
        )
    }

    private var recentMeetings: [Meeting] {
        viewModel.filteredRecentMeetings(from: meetingsProvider.meetings)
    }

    /// Groups the already-filtered, reverse-chronological `recentMeetings` into the
    /// five past recency buckets, returning only non-empty buckets in fixed order
    /// (Today → Earlier). Order within each bucket is preserved from `recentMeetings`.
    private var bucketedRecentMeetings: [(bucket: MeetingTimeBucket, meetings: [Meeting])] {
        let now = Date()
        let order: [MeetingTimeBucket] = [.today, .thisWeek, .thisMonth, .thisYear, .earlier]
        let grouped = Dictionary(grouping: recentMeetings) {
            MeetingTimeBucket.bucket(for: $0.date, now: now)
        }
        return order.compactMap { bucket in
            guard let meetings = grouped[bucket], !meetings.isEmpty else { return nil }
            return (bucket, meetings)
        }
    }

    private var upcomingMeetings: [Meeting] {
        viewModel.filteredUpcomingMeetings(from: meetingsProvider.meetings)
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
    var pipeline: MeetingPipelinePresentation? = nil
    var onPrepareRequest: () -> Void = {}
    let onDeleteRequest: () -> Void

    private var actions: SidebarMeetingRowActions {
        SidebarMeetingRowActions(section: section)
    }

    /// The row shows a processing/error glyph when the pipeline is active or
    /// failed; otherwise the resting status icon.
    private var isProcessing: Bool {
        pipeline?.isActive ?? false
    }

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            Group {
                if let pipeline, pipeline.isActive {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if let pipeline, pipeline.hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .imageScale(.small)
                        .foregroundStyle(Color.accentDanger)
                } else {
                    statusIcon
                }
            }
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
                case .prepare:
                    Button("Prepare…", systemImage: "doc.text.magnifyingglass", action: onPrepareRequest)
                case .deleteMeeting:
                    Button("Delete Meeting…", role: .destructive, action: onDeleteRequest)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meeting.title), \(isProcessing ? "Processing" : statusAccessibilityLabel), \(formattedDate)")
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

/// Shown for the brief moment before the windowed meetings provider is created
/// (it needs the modelContext, wired in ContentView's `.task`).
struct SidebarPlaceholderView: View {
    var body: some View {
        List {
            Section {
                Label("Dashboard", systemImage: "calendar")
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Sidebar Navigation Destination

enum SidebarDestination: Hashable {
    case dashboard
    case todos
    case actionQueue
    case meeting(UUID)
}
