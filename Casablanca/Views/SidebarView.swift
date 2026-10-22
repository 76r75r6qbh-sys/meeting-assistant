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
    @State private var deletionErrorMessage: String?
    /// Per-meeting grace-period tasks for soft-deletion. Cancelled on Undo.
    @State private var pendingDeletionTasks: [UUID: Task<Void, Never>] = [:]

    /// How long the user has to undo a deletion before it becomes permanent.
    private let deletionGracePeriod: Duration = .seconds(6)

    private var openTodoCount: Int { openTodos.count }

    var body: some View {
        // Read in this view's tracked context so the badge updates reactively
        // when the watcher/bootstrap mutates the queue.
        let pendingCount = appModel.actionQueueModel.pendingCount
        // Filtered/sorted once per body pass; they were computed twice each.
        let upcoming = upcomingMeetings
        let recent = recentMeetings
        let recentBuckets = Self.bucketed(recent)
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

            if !upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(upcoming) { meeting in
                        SidebarMeetingRow(
                            meeting: meeting,
                            section: .upcoming,
                            pipeline: pipelinePresentation(for: meeting),
                            onPrepareRequest: {
                                viewModel.beginPrepare(for: meeting)
                            },
                            onDeleteRequest: {
                                requestDelete(meeting)
                            }
                        )
                        .tag(SidebarDestination.meeting(meeting.id))
                    }
                }
            }

            if recent.isEmpty {
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
                ForEach(recentBuckets, id: \.bucket) { pair in
                    Section(pair.bucket.title) {
                        ForEach(pair.meetings) { meeting in
                            SidebarMeetingRow(
                                meeting: meeting,
                                section: .recent,
                                pipeline: pipelinePresentation(for: meeting),
                                onDeleteRequest: {
                                    requestDelete(meeting)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            tagFilterBar
        }
        // Push the sidebar's title search down into the provider's SQLite fetch.
        .onChange(of: viewModel.meetingSearchText) { _, new in
            meetingsProvider.searchText = new
        }
        .onAppear {
            meetingsProvider.searchText = viewModel.meetingSearchText
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

    /// Horizontal, scrollable row of tag-filter chips shown above the meeting
    /// list. Only appears when meetings in the window carry tags. OR semantics:
    /// selecting multiple chips shows meetings with ANY of them.
    @ViewBuilder
    private var tagFilterBar: some View {
        let tags = meetingsProvider.distinctTags
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CasaSpace.xs) {
                    if !meetingsProvider.selectedTags.isEmpty {
                        Button {
                            meetingsProvider.clearTagFilter()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.textTertiary)
                        .accessibilityLabel("Clear tag filter")
                    }
                    ForEach(tags, id: \.self) { tag in
                        TagChip(
                            text: tag,
                            isSelected: meetingsProvider.selectedTags.contains(tag),
                            onTap: { meetingsProvider.toggleTag(tag) }
                        )
                    }
                }
                .padding(.horizontal, CasaSpace.sm)
                .padding(.vertical, CasaSpace.xs)
            }
            .background(.bar)
            .casaAnimation(CasaAnimation.fast, value: meetingsProvider.selectedTags)
        }
    }

    /// The row's compact processing indicator. Only the meeting actually being
    /// processed or summarized gets one; every other row is described by its
    /// status alone (see `SidebarPipelineIndicator`).
    private func pipelinePresentation(for meeting: Meeting) -> MeetingPipelinePresentation? {
        SidebarPipelineIndicator.presentation(
            meetingID: meeting.id,
            status: meeting.status,
            isTranscribing: appModel.transcriptionService.isTranscribing,
            summarizingMeetingID: appModel.summarizationService.summarizingMeetingID,
            summarizationPhase: appModel.summarizationService.phase,
            summarizationStartedAt: appModel.summarizationService.summarizationStartedAt
        )
    }

    private var recentMeetings: [Meeting] {
        viewModel.filteredRecentMeetings(from: meetingsProvider.tagFilteredMeetings)
    }

    /// Groups the already-filtered, reverse-chronological recent meetings into the
    /// five past recency buckets, returning only non-empty buckets in fixed order
    /// (Today → Earlier). Order within each bucket is preserved.
    private static func bucketed(_ recentMeetings: [Meeting]) -> [(bucket: MeetingTimeBucket, meetings: [Meeting])] {
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
        viewModel.filteredUpcomingMeetings(from: meetingsProvider.tagFilteredMeetings)
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

    /// Soft-deletes a meeting: hides it immediately, shows an Undo toast, and
    /// schedules the real (file + model) delete after the grace period. Undo
    /// cancels the pending delete and un-hides the meeting.
    private func requestDelete(_ meeting: Meeting) {
        let id = meeting.id

        // Cancel any in-flight grace task for this meeting (re-delete edge case).
        pendingDeletionTasks[id]?.cancel()

        viewModel.beginSoftDelete(id)
        selection = viewModel.sidebarSelection

        appModel.toastCenter.show(
            message: "Meeting deleted",
            actionLabel: "Undo",
            action: {
                pendingDeletionTasks[id]?.cancel()
                pendingDeletionTasks[id] = nil
                viewModel.undoSoftDelete(id)
            },
            duration: 6
        )

        let task = Task { @MainActor in
            try? await Task.sleep(for: deletionGracePeriod)
            guard !Task.isCancelled else { return }
            pendingDeletionTasks[id] = nil
            do {
                try viewModel.commitSoftDelete(meeting)
                selection = viewModel.sidebarSelection
            } catch {
                // Hard delete failed — un-hide and surface the error.
                viewModel.undoSoftDelete(id)
                deletionErrorMessage = error.localizedDescription
            }
        }
        pendingDeletionTasks[id] = task
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

                if !meeting.tags.isEmpty {
                    TagChipStrip(tags: meeting.tags)
                }
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

/// Builds the sidebar row's processing indicator without touching the meeting's
/// heavy columns. `SidebarMeetingsProvider` deliberately leaves `transcript` and
/// `summary` out of its partial fetch; reading them for every row on every body
/// pass (and the sidebar re-rendered per transcription progress tick) faulted
/// them all back in.
///
/// The sidebar passes `autoSummarize: false`, and that is the only rule that
/// consults `hasTranscript`/`hasSummary`, so they are irrelevant here. The
/// row shows a spinner, never the percentage, so progress is not read either.
/// A meeting that is neither `.processing` nor the one being summarized derives
/// to `.done`, i.e. the plain status icon, so it gets no presentation at all.
enum SidebarPipelineIndicator {
    static func presentation(
        meetingID: UUID,
        status: MeetingStatus,
        isTranscribing: Bool,
        summarizingMeetingID: UUID?,
        summarizationPhase: SummarizationService.SummarizationPhase,
        summarizationStartedAt: Date?
    ) -> MeetingPipelinePresentation? {
        let isSummarizingThis = summarizingMeetingID == meetingID
        guard status == .processing || isSummarizingThis else { return nil }
        return MeetingPipelinePresentation(
            isThisMeetingTranscribing: isTranscribing && status == .processing,
            transcriptionProgress: 0,
            isSummarizingThisMeeting: isSummarizingThis,
            summarizationPhase: summarizationPhase,
            summarizationStartedAt: summarizationStartedAt,
            // Errors (summary/export) are surfaced in the detail view, not the
            // sidebar row, so the row only reflects active/stale state.
            summarizationError: nil,
            autoExportFailure: nil,
            meetingStatus: status,
            hasTranscript: false,
            hasSummary: false,
            autoSummarize: false,
            autoExport: false
        )
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
