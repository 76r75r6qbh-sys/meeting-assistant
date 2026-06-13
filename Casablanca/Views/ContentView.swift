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
    @State private var detailRoute: SidebarDestination? = .dashboard
    @State private var showSearch = false
    @AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode) private var recordingWorkspaceFocusMode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Focus mode is only meaningful inside a meeting workspace.
    private var isFocusModeActive: Bool {
        guard recordingWorkspaceFocusMode, case .meeting = detailRoute else { return false }
        return true
    }

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
                    actionQueueModel: appModel.actionQueueModel
                )
            }
            try? ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
        }
        .task {
            if interruptionCoordinator == nil {
                recordingService.interruptionMonitor = interruptionMonitor
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
        .onChange(of: isFocusModeActive) { _, focused in
            withAnimation(reduceMotion ? nil : CasaAnimation.standard) {
                columnVisibility = focused ? .detailOnly : .automatic
            }
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
                        onRecordAgain: {
                            viewModel.beginRecording(for: meeting)
                        },
                        onTranscribe: {
                            meeting.status = .processing
                            try? modelContext.save()
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
