import SwiftUI
import SwiftData

struct TranscriptionView: View {
    @Bindable var meeting: Meeting
    @Bindable var transcriptionService: TranscriptionService
    let onComplete: () -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    private var terminologyService: TerminologyService { appModel.terminologyService }
    @AppStorage(AppPreferenceKey.autoSummarizeAfterTranscription) private var autoSummarizeAfterTranscription = false
    @AppStorage(AppPreferenceKey.autoExportEnabled) private var autoExportEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Divider()
            segmentsList
        }
        .navigationTitle("\(meeting.title) \u{00B7} Transcribing")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    transcriptionService.cancel()
                    onCancel()
                }
                .disabled(!transcriptionService.isTranscribing)
            }
        }
        // The run belongs to the service, so this only asks for it: a re-appearing
        // view re-triggers the task and the service ignores the duplicate.
        .task {
            startTranscription()
        }
        // Completion no longer arrives as a return from this view's own task —
        // the pipeline can outlive the view — so it arrives as service state.
        .onChange(of: transcriptionService.lastCompletedMeetingID) { _, completedID in
            if completedID == meeting.id {
                onComplete()
            }
        }
        .alert("Transcription Error", isPresented: errorBinding) {
            Button("Retry") {
                transcriptionService.clearError()
                startTranscription()
            }
            Button("Skip Transcription", role: .cancel) {
                transcriptionService.clearError()
                meeting.status = .completed
                save()
                onComplete()
            }
        } message: {
            Text(transcriptionService.lastError?.localizedDescription ?? "An unknown error occurred.")
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack {
                HStack(spacing: CasaSpace.sm) {
                    if transcriptionService.isTranscribing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentSuccess)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Text(transcriptionService.statusMessage.isEmpty ? "Preparing\u{2026}" : transcriptionService.statusMessage)
                        .font(.headline)
                        .foregroundStyle(Color.textPrimary)
                        .contentTransition(.opacity)
                }
                .animation(reduceMotion ? nil : CasaAnimation.standard, value: transcriptionService.isTranscribing)

                Spacer()

                Text("\(Int(transcriptionService.progress * 100))%")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
            }

            ProgressView(value: transcriptionService.progress, total: 1.0)
                .tint(Color.accentSecondary)

            if !transcriptionService.currentSegments.isEmpty {
                Text("\(transcriptionService.currentSegments.count) segments transcribed")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            if autoSummarizeAfterTranscription {
                Text(pipelineMessage)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(CasaSpace.xl)
    }

    private var segmentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CasaSpace.sm) {
                    ForEach(transcriptionService.currentSegments) { segment in
                        HStack(alignment: .top, spacing: CasaSpace.sm) {
                            Text(segment.formattedTimestamp)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Color.textSecondary)
                                .frame(width: 60, alignment: .leading)

                            Text(segment.text)
                                .font(.body)
                                .foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled)
                        }
                        .id(segment.id)
                    }
                }
                .padding(CasaSpace.xl)
            }
            .onChange(of: transcriptionService.currentSegments.count) {
                // Auto-scroll to latest segment
                if let last = transcriptionService.currentSegments.last {
                    withAnimation(CasaAnimation.standard) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { transcriptionService.lastError != nil },
            set: { if !$0 { transcriptionService.clearError() } }
        )
    }

    /// Asks the service to run the pipeline for this meeting. A no-op while a
    /// run is already in flight, so re-entering the view cannot start a second
    /// transcription on the same WhisperKit instance.
    private func startTranscription() {
        transcriptionService.transcribeInBackground(
            meeting: meeting,
            modelContext: modelContext,
            terminologyService: terminologyService,
            exportReporter: appModel.exportStatusCenter
        )
    }

    private func save() {
        try? modelContext.save()
    }

    private var pipelineMessage: String {
        if autoExportEnabled {
            let destinationName: String = {
                switch AppPreferences.exportDestination() {
                case .obsidian: return "Obsidian"
                case .appleNotes: return "Apple Notes"
                }
            }()
            return "After transcription, Casablanca will continue through summary and export to \(destinationName) automatically."
        }
        return "After transcription, Casablanca will continue to summary automatically."
    }
}
