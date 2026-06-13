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
    @State private var didStart = false
    @State private var error: TranscriptionError?
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

            // Transcription has finished reading the WAV. Now (and only now) is
            // it safe to compress the recording to AAC/m4a and reclaim disk.
            await compressRecordingIfEnabled(wavURL: fileURL)

            _ = try? TranscriptionService.saveTranscriptLocally(meeting: meeting, result: result)
            await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: appModel.exportStatusCenter)

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

    /// Re-encodes the finished WAV mixdown to AAC/m4a and repoints the meeting
    /// at the smaller file, deleting the WAV on success. Skipped entirely when
    /// the user has opted to keep the original WAV. On any failure the WAV is
    /// preserved and the meeting keeps pointing at it — the recording is never
    /// lost.
    private func compressRecordingIfEnabled(wavURL: URL) async {
        guard !AppPreferences.keepOriginalWAV() else { return }
        // Only compress lossless WAV input; never re-compress an already-m4a file.
        guard wavURL.pathExtension.lowercased() == "wav" else { return }

        do {
            let m4aURL = try await RecordingCompressor.compress(wavURL: wavURL)

            // The meeting may have been deleted mid-compression; if so, leave the
            // newly written m4a to be cleaned up with the meeting's other files.
            guard meeting.modelContext != nil else { return }

            meeting.recordingFileURL = m4aURL.path
            save()

            // WAV is no longer referenced — reclaim its disk space.
            bestEffort("delete WAV after compression", Log.recording) {
                try FileManager.default.removeItem(at: wavURL)
            }
            Log.recording.info("Compressed recording to AAC/m4a; deleted original WAV.")
        } catch {
            // Keep the WAV and leave the meeting pointing at it.
            Log.recording.error("Recording compression failed; keeping WAV: \(error.localizedDescription, privacy: .public)")
        }
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
