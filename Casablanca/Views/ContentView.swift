import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: MeetingListViewModel
    @State private var recordingService = AudioRecordingService()
    @State private var transcriptionService = TranscriptionService()
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
        case .meeting(let id):
            if let meeting = viewModel.selectedMeeting ?? viewModel.fetchMeeting(byID: id) {
                switch meeting.status {
                case .notesOnly, .upcoming:
                    NotesEditorView(
                        meeting: meeting,
                        onStartRecording: {
                            viewModel.beginRecording(for: meeting)
                        },
                        onBack: {
                            viewModel.selectedMeeting = nil
                        }
                    )
                case .recording:
                    RecordingView(
                        meeting: meeting,
                        recordingService: recordingService,
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
