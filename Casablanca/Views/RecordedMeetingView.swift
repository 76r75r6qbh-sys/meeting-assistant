import AppKit
import SwiftUI

struct RecordedMeetingView: View {
    @Bindable var meeting: Meeting
    let onRecordAgain: () -> Void
    let onTranscribe: () -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.autoSummarizeAfterTranscription) private var autoSummarizeAfterTranscription = false
    @AppStorage(AppPreferenceKey.autoExportEnabled) private var autoExportEnabled = false
    @Environment(AppModel.self) private var appModel
    private var summarizationService: SummarizationService { appModel.summarizationService }
    private var terminologyService: TerminologyService { appModel.terminologyService }
    private var transcriptionService: TranscriptionService { appModel.transcriptionService }
    private var exportStatusCenter: ExportStatusCenter { appModel.exportStatusCenter }
    @State private var didTriggerAutomaticSummary = false
    @State private var selectedTab: DetailTab = .summary
    @State private var showInspector = true
    // Owned by this long-lived view so they survive tab switches: the notes
    // edit toggle persists, and a pending debounced save is not cancelled when
    // the user leaves the Notes tab (which tears down MeetingNotesTab).
    @State private var isEditingNotes = false
    @State private var saveTask: Task<Void, Never>?
    // In-memory chat, owned by this detail view so it survives tab switches and
    // resets when the user navigates to a different meeting (keyed internally by
    // meeting id). No persistence in v1.
    @State private var chatService = MeetingChatService()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"
        case ask = "Ask"

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            readingColumn
                .padding(CasaSpace.xl)
                .frame(maxWidth: CasaLayout.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Native trailing inspector (AppKit-driven resize, HIG-compliant).
        .inspector(isPresented: $showInspector) {
            MeetingDetailInspector(meeting: meeting, canExport: canExport)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 560)
        }
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let primaryToolbarAction {
                    toolbarButton(for: primaryToolbarAction, isPrimary: true)
                }

                Button {
                    withAnimation(reduceMotion ? nil : CasaAnimation.fast) { showInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide inspector" : "Show inspector")

                secondaryActionsMenu
            }
        }
        .task(id: meeting.id) {
            terminologyService.clearWarning()
            await triggerAutomaticSummaryIfNeeded()
        }
        .alert("Summary Error", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {
                summarizationService.clearError()
            }
        } message: {
            Text(summarizationService.errorMessage ?? "Unable to summarize the meeting.")
        }
    }

    // MARK: - Reading column

    private var readingColumn: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xl) {
            infoBar

            Picker("View", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if shouldShowPipelineCard {
                ProcessingStatusCard(
                    presentation: pipelinePresentation,
                    transcriptionProgress: transcriptionService.progress,
                    summarizationStartedAt: summarizationService.summarizationStartedAt,
                    onCancel: cancelActiveStage,
                    onRetry: retryFailedStage,
                    onDismissError: dismissPipelineError,
                    onDismissWarning: { summarizationService.clearWarning() }
                )
            }

            switch selectedTab {
            case .summary:
                MeetingSummaryTab(
                    meeting: meeting,
                    isSummarizing: isSummarizingThisMeeting,
                    statusMessage: summarizationService.statusMessage,
                    canSummarize: canSummarize,
                    onSummarize: {
                        summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
                    }
                )
            case .transcript:
                MeetingTranscriptTab(
                    meeting: meeting,
                    terminologyService: terminologyService,
                    onTranscribe: onTranscribe,
                    onSave: save
                )
            case .notes:
                MeetingNotesTab(
                    meeting: meeting,
                    isEditingNotes: $isEditingNotes,
                    onNotesEdited: debouncedSave
                )
            case .ask:
                MeetingChatTab(
                    meeting: meeting,
                    chatService: chatService,
                    hasGroundingContent: hasGroundingContent,
                    // The local LLM serializes requests — a chat during any
                    // background summary would queue and risk the 120s timeout.
                    isSummaryInProgress: summarizationService.summarizingMeetingID != nil
                )
            }

            Spacer(minLength: 0)
        }
    }

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack(spacing: CasaSpace.md) {
                Label(meeting.formattedTime, systemImage: "calendar")

                if let duration = meeting.recordingDuration {
                    Label(duration.formattedRecordingDuration, systemImage: "timer")
                }

                if recordingURL != nil {
                    Label("Recording saved locally", systemImage: "waveform")
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.textSecondary)
            .symbolRenderingMode(.hierarchical)

            if meeting.transcript == nil, recordingURL != nil {
                HStack(spacing: CasaSpace.md) {
                    Text("Language")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)

                    Picker("Language", selection: $meeting.transcriptionLanguage) {
                        ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: meeting.transcriptionLanguage) {
                        save()
                    }
                }
            }
        }
    }

    /// Pure presentation driving the ProcessingStatusCard, built fresh each render
    /// from the live services + this meeting's state.
    private var pipelinePresentation: MeetingPipelinePresentation {
        MeetingPipelinePresentation(
            isThisMeetingTranscribing: isTranscribingThisMeeting,
            transcriptionProgress: transcriptionService.progress,
            isSummarizingThisMeeting: isSummarizingThisMeeting,
            summarizationPhase: summarizationService.phase,
            summarizationStartedAt: summarizationService.summarizationStartedAt,
            summarizationError: summarizationService.errorMessage,
            summarizationWarning: summarizationService.warningMessage,
            autoExportFailure: exportStatusCenter.failure(for: meeting.id),
            meetingStatus: meeting.status,
            hasTranscript: meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasSummary: meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            autoSummarize: autoSummarizeAfterTranscription,
            autoExport: autoExportEnabled
        )
    }

    /// True while this meeting is the one actively transcribing. Transcription is
    /// app-wide and ordinarily runs in TranscriptionView, but the meeting carries
    /// `.processing` for its duration, so we scope by that + the service flag.
    private var isTranscribingThisMeeting: Bool {
        transcriptionService.isTranscribing && meeting.status == .processing
    }

    private func cancelActiveStage() {
        switch pipelinePresentation.stage {
        case .transcribing:
            transcriptionService.cancel()
        case .summarizing:
            summarizationService.cancelBackgroundWork()
        default:
            break
        }
    }

    private func retryFailedStage() {
        guard case .failed(let stage, _) = pipelinePresentation.stage else { return }
        switch stage {
        case .transcription:
            onTranscribe()
        case .summarization:
            summarizationService.clearError()
            summarizationService.clearWarning()
            summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
        case .export:
            exportStatusCenter.clearFailure(for: meeting.id)
            Task { @MainActor in
                await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: exportStatusCenter)
            }
        }
    }

    private func dismissPipelineError() {
        guard case .failed(let stage, _) = pipelinePresentation.stage else { return }
        switch stage {
        case .transcription:
            break
        case .summarization:
            summarizationService.clearError()
            summarizationService.clearWarning()
        case .export:
            exportStatusCenter.clearFailure(for: meeting.id)
        }
    }

    @ViewBuilder
    private func toolbarButton(for action: ReviewPrimaryAction, isPrimary: Bool) -> some View {
        switch action {
        case .transcribe:
            Button(action: onTranscribe) {
                Label("Transcribe", systemImage: "waveform")
            }
        case .summarize:
            Button {
                summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
            } label: {
                Label("Summarize", systemImage: isSummarizingThisMeeting ? "hourglass" : "sparkles")
            }
            .disabled(!canSummarize || summarizationService.isSummarizing)
        case .export:
            Button {
                exportMeeting()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!canExport)
        }
    }

    private var hasNotes: Bool {
        !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSummarize: Bool {
        meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || hasNotes
    }

    /// Whether there's anything to ground a chat answer on — a transcript or a
    /// summary. (Notes alone aren't enough signal for grounded Q&A; the summary
    /// captures notes anyway.)
    private var hasGroundingContent: Bool {
        meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var canExport: Bool {
        meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || hasNotes
    }

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True only when the shared summarization service is processing THIS
    /// meeting — the service is app-wide, so other meetings' detail views must
    /// not show this one's "generating…" state.
    private var isSummarizingThisMeeting: Bool {
        summarizationService.isSummarizing
            && summarizationService.summarizingMeetingID == meeting.id
    }

    /// Show the pipeline card whenever a stage is active, there's an error to
    /// surface (incl. auto-export failures), or there's a non-fatal warning to
    /// show (a success-with-caveat). Otherwise `.done`/`.idle` hide it.
    private var shouldShowPipelineCard: Bool {
        pipelinePresentation.isActive
            || pipelinePresentation.hasError
            || pipelinePresentation.warning != nil
    }

    private var canReapplyTerminology: Bool {
        guard meeting.rawTranscript != nil else { return false }
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled) else { return false }
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        return !TerminologyService.parse(raw).isEmpty
    }

    private var primaryToolbarAction: ReviewPrimaryAction? {
        reviewPrimaryAction(
            hasTranscript: meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasRecording: recordingURL != nil,
            hasSummary: meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            canSummarize: canSummarize,
            canExport: canExport
        )
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(
            get: { summarizationService.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    summarizationService.clearError()
                }
            }
        )
    }

    private func reapplyTerminology() async {
        guard let raw = meeting.rawTranscript else { return }
        let entries = TerminologyService.parse(
            UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )
        guard !entries.isEmpty else { return }

        let corrected = await terminologyService.correct(raw, entries: entries)
        guard meeting.modelContext != nil else { return }
        meeting.transcript = corrected
        save()
    }

    private func exportMeeting() {
        save()

        Task { @MainActor in
            do {
                let result = try await ExportService.exportCompletedMeeting(meeting)
                switch result {
                case .obsidian(let export):
                    let message: String
                    if export.summaryURL != nil {
                        message = "Saved the summary note and raw notes to your Obsidian meeting notes folder."
                    } else {
                        message = "Saved raw notes to Obsidian. Generate a summary and export again to add the summary note."
                    }
                    presentExportAlert(
                        title: "Export Complete",
                        message: message,
                        exportedURLs: export.exportedURLs
                    )
                case .appleNotes:
                    presentExportAlert(
                        title: "Export Complete",
                        message: "Saved to Apple Notes folder \"Casablanca\".",
                        exportedURLs: []
                    )
                }
            } catch {
                presentExportAlert(
                    title: "Export Failed",
                    message: error.localizedDescription,
                    exportedURLs: []
                )
            }
        }
    }

    // MARK: - Secondary actions menu

    private var secondaryActionsMenu: some View {
        Menu {
            if primaryToolbarAction != .export, canExport {
                Button {
                    exportMeeting()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }

            if meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, recordingURL != nil {
                Button {
                    onTranscribe()
                } label: {
                    Label("Re-transcribe", systemImage: "waveform")
                }
            }

            if canReapplyTerminology {
                Button {
                    Task { await reapplyTerminology() }
                } label: {
                    Label("Re-apply terminology", systemImage: "wand.and.sparkles")
                }
                .disabled(terminologyService.isCorrecting)
            }

            Button(action: onRecordAgain) {
                Label("Record Again", systemImage: "record.circle")
            }

            if let recordingURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([recordingURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private func save() {
        try? modelContext.save()
        Task { @MainActor in
            await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: exportStatusCenter)
        }
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func triggerAutomaticSummaryIfNeeded() async {
        guard !didTriggerAutomaticSummary,
              autoSummarizeAfterTranscription,
              meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        else {
            return
        }

        didTriggerAutomaticSummary = true
        // Runs in a service-owned background task — keeps going if the user
        // leaves this screen, and silently saves extracted to-dos on completion.
        summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
    }
}
