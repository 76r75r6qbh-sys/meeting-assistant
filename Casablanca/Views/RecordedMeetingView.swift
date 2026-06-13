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
    @State private var didTriggerAutomaticSummary = false
    @State private var selectedTab: DetailTab = .summary
    @State private var showInspector = true
    // Owned by this long-lived view so they survive tab switches: the notes
    // edit toggle persists, and a pending debounced save is not cancelled when
    // the user leaves the Notes tab (which tears down MeetingNotesTab).
    @State private var isEditingNotes = false
    @State private var saveTask: Task<Void, Never>?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"

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
                    withAnimation(CasaAnimation.fast) { showInspector.toggle() }
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

            if shouldShowPipelineBanner {
                pipelineBanner
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

    private var pipelineBanner: some View {
        GroupBox {
            HStack(spacing: CasaSpace.sm) {
                if isSummarizingThisMeeting || terminologyService.isCorrecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.textSecondary)
                }

                Text(pipelineStatusText)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var shouldShowPipelineBanner: Bool {
        terminologyService.isCorrecting
            || isSummarizingThisMeeting
            || (autoSummarizeAfterTranscription
                && meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
    }

    private var canReapplyTerminology: Bool {
        guard meeting.rawTranscript != nil else { return false }
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled) else { return false }
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        return !TerminologyService.parse(raw).isEmpty
    }

    private var pipelineStatusText: String {
        if terminologyService.isCorrecting {
            return "Correcting terminology..."
        }

        if isSummarizingThisMeeting {
            return summarizationService.statusMessage.isEmpty ? "Generating summary..." : summarizationService.statusMessage
        }

        if autoSummarizeAfterTranscription && autoExportEnabled {
            return "Casablanca is moving this meeting through summary and export automatically."
        }

        if autoSummarizeAfterTranscription {
            return "Casablanca will generate the summary automatically."
        }

        return "The next recommended step is ready in the toolbar."
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
    }

    private func save() {
        try? modelContext.save()
        Task { @MainActor in
            await ExportService.exportAutomaticallyIfEnabled(meeting)
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
