import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State var viewModel: MeetingListViewModel
    @State private var recordingService = AudioRecordingService()
    @State private var transcriptionService = TranscriptionService()

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
        } detail: {
            detailView
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: CasaLayout.sidebarWidth, max: 260)
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let meeting = viewModel.selectedMeeting {
            switch meeting.status {
            case .notesOnly:
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
                    onComplete: {
                        // Stay on the same meeting — it will switch to .completed
                    },
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
            case .upcoming:
                DashboardView(viewModel: viewModel)
            }
        } else {
            DashboardView(viewModel: viewModel)
        }
    }
}
