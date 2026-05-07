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
    @AppStorage(AppPreferenceKey.autoExportNotesToObsidian) private var autoExportNotesToObsidian = false
    @State private var didStart = false
    @State private var error: TranscriptionError?

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
        .task {
            await startTranscription()
        }
        .alert("Transcription Error", isPresented: errorBinding) {
            Button("Retry") {
                didStart = false
                error = nil
                Task { await startTranscription() }
            }
            Button("Skip Transcription", role: .cancel) {
                meeting.status = .completed
                save()
                onComplete()
            }
        } message: {
            Text(error?.localizedDescription ?? "An unknown error occurred.")
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
                    }

                    Text(transcriptionService.statusMessage.isEmpty ? "Preparing..." : transcriptionService.statusMessage)
                        .font(.headline)
                        .foregroundStyle(Color.textPrimary)
                }

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
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )
    }

    private func startTranscription() async {
        guard !didStart else { return }
        didStart = true

        guard let recordingPath = meeting.recordingFileURL else {
            error = .fileNotFound("No recording file available")
            return
        }

        let fileURL = URL(fileURLWithPath: recordingPath)

        do {
            meeting.status = .processing
            save()

            let result = try await transcriptionService.transcribe(fileURL: fileURL, localeIdentifier: meeting.transcriptionLanguage)

            let correctionEnabled = UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled)
            let terminologyRaw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
            let entries = correctionEnabled ? TerminologyService.parse(terminologyRaw) : []

            let finalTranscript: String
            if !entries.isEmpty {
                meeting.rawTranscript = result.formattedTranscript
                save()
                let corrected = await terminologyService.correct(result.formattedTranscript, entries: entries)
                // Guard against the meeting being deleted mid-correction.
                guard meeting.modelContext != nil else { return }
                finalTranscript = corrected
            } else {
                meeting.rawTranscript = nil
                finalTranscript = result.formattedTranscript
            }

            meeting.transcript = finalTranscript
            meeting.status = .completed
            save()

            _ = try? TranscriptionService.saveTranscriptLocally(meeting: meeting, result: result)
            ExportService.exportAutomaticallyIfEnabled(meeting)

            onComplete()
        } catch is CancellationError {
            // User cancelled — handled by cancel button
        } catch let transcriptionError as TranscriptionError {
            error = transcriptionError
            didStart = false
        } catch {
            self.error = .transcriptionFailed(error.localizedDescription)
            didStart = false
        }
    }

    private func save() {
        try? modelContext.save()
    }

    private var pipelineMessage: String {
        if autoExportNotesToObsidian {
            return "After transcription, Casablanca will continue through summary and export automatically."
        }
        return "After transcription, Casablanca will continue to summary automatically."
    }
}
