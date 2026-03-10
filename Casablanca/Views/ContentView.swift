import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State var viewModel: MeetingListViewModel

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
                        meeting.status = .recording
                        // Recording will be handled in Phase 2
                    },
                    onBack: {
                        viewModel.selectedMeeting = nil
                    }
                )
            case .recording:
                // Placeholder for Phase 2
                VStack {
                    Image(systemName: "waveform")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.stateRecording)
                    Text("Recording view coming in Phase 2")
                        .font(.headline)
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .processing:
                // Placeholder for Phase 3/5
                VStack {
                    ProgressView()
                    Text("Processing...")
                        .font(.headline)
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .completed:
                // Placeholder for Phase 6
                VStack {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentSuccess)
                    Text("Review view coming in Phase 6")
                        .font(.headline)
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .upcoming:
                DashboardView(viewModel: viewModel)
            }
        } else {
            DashboardView(viewModel: viewModel)
        }
    }
}
