import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: MeetingListViewModel
    @Environment(AppModel.self) private var appModel
    private var recordingService: AudioRecordingService { appModel.recordingService }
    private var transcriptionService: TranscriptionService { appModel.transcriptionService }
    @State private var interruptionMonitor = RecordingInterruptionMonitor()
    @State private var interruptionNotifier = RecordingNotificationCenter()
    @State private var interruptionCoordinator: RecordingInterruptionCoordinator?
    @State private var sidebarMeetings: SidebarMeetingsProvider?
    @State private var searchViewModel: GlobalSearchViewModel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var windowWidth: CGFloat = CasaLayout.windowDefaultWidth
    @State private var detailRoute: SidebarDestination? = .dashboard
    @State private var showSearch = false
    @AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode) private var recordingWorkspaceFocusMode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .navigationSplitViewColumnWidth(min: 200, ideal: CasaLayout.sidebarWidth, max: 260)
        } detail: {
            detailView
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
            try? ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
        }
        .task {
            if interruptionCoordinator == nil {
                recordingService.interruptionMonitor = interruptionMonitor
                // Strong capture is intentional and non-cyclic: the notifier
                // holds no back-reference to the service, and both live for the
                // app's lifetime. A weak capture could let the notifier vanish
                // and silently drop the mic-only notice.
                recordingService.onSystemAudioUnavailable = { [interruptionNotifier] body in
                    interruptionNotifier.post(title: "Recording microphone only", body: body)
                }
                let context = modelContext
                interruptionCoordinator = RecordingInterruptionCoordinator(
                    service: recordingService,
                    monitor: interruptionMonitor,
                    notifier: interruptionNotifier,
                    save: { try? context.save() }
                )
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
        .onChange(of: viewModel.sidebarSelection) { _, new in
            detailRoute = new
        }
        .onChange(of: isFocusModeActive) { _, _ in
            updateColumnVisibility()
        }
        .onChange(of: widthClass, initial: true) { _, _ in
            updateColumnVisibility()
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
        case .meeting(let id):
            if let meeting = viewModel.selectedMeeting ?? viewModel.fetchMeeting(byID: id) {
                switch meeting.status.detailPresentation {
                case .workspace:
                    NotesEditorView(
                        meeting: meeting,
                        recordingService: recordingService,
                        interruptionCoordinator: interruptionCoordinator,
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
                        widthClass: widthClass,
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
