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
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var detailRoute: SidebarDestination? = .dashboard

    var body: some View {
        // Force @Observable tracking in ContentView's own body context, not inside
        // the NavigationSplitView detail closure (which has its own rendering context).
        let _ = viewModel.sidebarSelection
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 200, ideal: CasaLayout.sidebarWidth, max: 260)
        } detail: {
            detailView
        }
        .task {
            viewModel.setModelContext(modelContext)
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
