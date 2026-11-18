import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: MeetingListViewModel
    @Environment(AppModel.self) private var appModel
    private var recordingService: AudioRecordingService { appModel.recordingService }
    private var transcriptionService: TranscriptionService { appModel.transcriptionService }
    // The interruption monitor/coordinator live on `AppModel` (created once at
    // bootstrap), not here: window `@State` died with the window, which ended
    // sleep deferral and auto-pause for a recording still running in the
    // background, and a reopened window built a duplicate set.
    @State private var sidebarMeetings: SidebarMeetingsProvider?
    @State private var searchViewModel: GlobalSearchViewModel?
    @State private var askService: AskService?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var windowWidth: CGFloat = CasaLayout.windowDefaultWidth
    @State private var detailRoute: SidebarDestination? = .dashboard
    @State private var showSearch = false
    @AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode) private var recordingWorkspaceFocusMode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Timestamp-link clicks anywhere in the window land here first.
    private let navigator = MeetingDetailNavigator.shared

    /// Focus mode is only meaningful inside a meeting workspace.
    private var isFocusModeActive: Bool {
        guard recordingWorkspaceFocusMode, case .meeting = detailRoute else { return false }
        return true
    }

    /// Responsive tier derived from the live window width.
    private var widthClass: LayoutWidthClass { .from(width: windowWidth) }

    var body: some View {
        // Force @Observable tracking in ContentView's own body context, not inside
        // the NavigationSplitView detail closure (which has its own rendering context).
        let _ = viewModel.sidebarSelection
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if let sidebarMeetings {
                    SidebarView(viewModel: viewModel, meetingsProvider: sidebarMeetings)
                } else {
                    // Provider is created in `.task` once the modelContext is
                    // available; show nothing meaningful for the brief gap.
                    SidebarPlaceholderView()
                }
            }
            .navigationSplitViewColumnWidth(min: CasaLayout.sidebarMinWidth, ideal: CasaLayout.sidebarWidth, max: CasaLayout.sidebarMaxWidth)
        } detail: {
            detailView
                .stableSplitColumnMinimumSize(minWidth: CasaLayout.detailColumnMinWidth)
                // Trailing inspectors in the detail column read this to stay
                // closed while the window is too narrow (`widthGatedInspector`).
                .environment(\.layoutWidthClass, widthClass)
        }
        .background {
            // Single source of truth for the window width that drives the
            // responsive sidebar/inspector layout.
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    windowWidth = width
                }
            }
        }
        .toastOverlay(appModel.toastCenter)
        // `[mm:ss]` links in the summary, to-dos and transcript lines.
        .handlesTimestampLinks(navigator)
        .toolbar {
            ToolbarItem {
                Button {
                    showSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search everything (\u{2318}F)")
            }
        }
        .background(
            // Hidden command target so ⌘F works from anywhere in the window.
            Button("Search") { showSearch = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        )
        .sheet(isPresented: $showSearch) {
            if let searchViewModel {
                GlobalSearchView(
                    searchViewModel: searchViewModel,
                    viewModel: viewModel,
                    onDismiss: { showSearch = false }
                )
            }
        }
        .sheet(item: prepMeetingBinding) { meeting in
            PrepEditorView(
                meeting: meeting,
                onStartRecording: {
                    viewModel.beginRecording(for: meeting)
                },
                onDismiss: { viewModel.prepMeeting = nil }
            )
        }
        .alert("Data Error", isPresented: persistenceErrorBinding) {
            Button("OK", role: .cancel) {
                viewModel.persistenceErrorMessage = nil
            }
        } message: {
            Text(viewModel.persistenceErrorMessage ?? "Unknown error")
        }
        .task {
            viewModel.setModelContext(modelContext)
            // Automatic exports skip meetings in the delete grace period.
            MeetingExportCoalescer.shared.isPendingDeletion = { [viewModel] id in viewModel.isPendingDeletion(id) }
            if sidebarMeetings == nil {
                sidebarMeetings = SidebarMeetingsProvider(modelContext: modelContext)
            }
            if searchViewModel == nil {
                searchViewModel = GlobalSearchViewModel(
                    modelContext: modelContext,
                    actionQueueModel: appModel.actionQueueModel,
                    isPendingDeletion: { [viewModel] id in viewModel.isPendingDeletion(id) }
                )
            }
            if askService == nil {
                // Paged background snapshot loading on the shared container,
                // debounced invalidation on store saves.
                askService = AskService(
                    container: modelContext.container,
                    isPendingDeletion: { [viewModel] id in viewModel.isPendingDeletion(id) }
                )
            }
            try? ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
        .onChange(of: viewModel.sidebarSelection) { _, new in
            detailRoute = new
        }
        .onChange(of: navigator.pendingJump) { _, jump in
            if let jump { openMeeting(for: jump) }
        }
        .onChange(of: viewModel.pendingDeletionIDs) { _, _ in
            askService?.refreshFilterOptions()
        }
        .onChange(of: isFocusModeActive) { _, _ in
            updateColumnVisibility()
        }
        .onChange(of: widthClass, initial: true) { _, _ in
            updateColumnVisibility()
        }
    }

    /// Selects the jump's meeting. RecordedMeetingView carries the jump out
    /// (transcript tab, scroll, playback) and completes it. A meeting that is
    /// gone, pending deletion or not completed (recording, transcribing: no
    /// transcript tab to scroll) is only selected when it exists, and the
    /// jump is completed here so it cannot fire later.
    private func openMeeting(for jump: TimestampJump) {
        guard !viewModel.isPendingDeletion(jump.meetingID),
              let meeting = viewModel.fetchMeeting(byID: jump.meetingID) else {
            navigator.complete(jump)
            return
        }
        viewModel.sidebarSelection = .meeting(jump.meetingID)
        if meeting.status.detailPresentation != .completed {
            navigator.complete(jump)
        }
    }

    /// Drives the leading sidebar visibility from both focus mode and the
    /// responsive width tier. Focus mode wins; otherwise a `.compact` window
    /// collapses the sidebar gracefully instead of letting NavigationSplitView
    /// silently drop it.
    private func updateColumnVisibility() {
        let collapse = isFocusModeActive || widthClass == .compact
        withAnimation(reduceMotion ? nil : CasaAnimation.standard) {
            columnVisibility = collapse ? .detailOnly : .automatic
        }
    }

    private var persistenceErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.persistenceErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.persistenceErrorMessage = nil
                }
            }
        )
    }

    private var prepMeetingBinding: Binding<Meeting?> {
        Binding(
            get: { viewModel.prepMeeting },
            set: { viewModel.prepMeeting = $0 }
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch detailRoute {
        case .todos:
            TodosView(viewModel: viewModel)
        case .actionQueue:
            ActionQueueView()
        case .ask:
            if let askService {
                AskView(
                    service: askService,
                    isSummaryInProgress: appModel.summarizationService.summarizingMeetingID != nil,
                    // The single seam for citation taps: a citation with a
                    // time jumps there (transcript + audio); without one it
                    // only opens the meeting. Bare `[mm:ss]` in an Ask
                    // answer have no meeting context and stay plain text
                    // (no `TimestampLinkText`).
                    onOpenCitation: { target in
                        // A meeting deleted (pending undo) after the answer
                        // arrived must not reopen.
                        guard !viewModel.isPendingDeletion(target.meetingID) else { return }
                        if let seconds = target.seconds {
                            navigator.jump(to: target.meetingID, seconds: seconds)
                        } else {
                            viewModel.sidebarSelection = .meeting(target.meetingID)
                        }
                    }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .meeting(let id):
            if let meeting = viewModel.selectedMeeting ?? viewModel.fetchMeeting(byID: id) {
                switch meeting.status.detailPresentation {
                case .workspace:
                    NotesEditorView(
                        meeting: meeting,
                        recordingService: recordingService,
                        interruptionCoordinator: appModel.interruptionCoordinator,
                        autoStartRecording: meeting.status == .recording,
                        onBack: {
                            viewModel.selectedMeeting = nil
                        }
                    )
                case .processing:
                    TranscriptionView(
                        meeting: meeting,
                        transcriptionService: transcriptionService,
                        onComplete: {},
                        onCancel: {
                            meeting.status = .completed
                            try? modelContext.save()
                        }
                    )
                case .completed:
                    RecordedMeetingView(
                        meeting: meeting,
                        onRecordAgain: {
                            viewModel.beginRecording(for: meeting)
                        },
                        onTranscribe: {
                            meeting.status = .processing
                            try? modelContext.save()
                        },
                        onSelectMeeting: { target in
                            viewModel.selectedMeeting = target
                        }
                    )
                }
            } else {
                DashboardView(viewModel: viewModel)
            }
        case .dashboard, .none:
            DashboardView(viewModel: viewModel)
        }
    }
}
