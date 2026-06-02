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
    @State private var isEditingNotes = false
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerAutomaticSummary = false
    @State private var selectedTab: DetailTab = .summary
    @State private var showInspector = true

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
            inspector
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
                summaryTab
            case .transcript:
                transcriptTab
            case .notes:
                notesTab
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

    // MARK: - Summary tab

    @ViewBuilder
    private var summaryTab: some View {
        if isSummarizingThisMeeting {
            HStack(spacing: CasaSpace.sm) {
                ProgressView()
                    .controlSize(.small)

                Text(summarizationService.statusMessage.isEmpty ? "Generating summary..." : summarizationService.statusMessage)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let summary = meeting.summary,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = SummaryResponseParser.parse(summary)

            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                summaryHero(parsed)

                if !parsed.decisions.isEmpty {
                    parsedSection("Decisions", systemImage: "diamond.fill") {
                        ForEach(Array(parsed.decisions.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "diamond.fill", color: Color.accentSuccess, text: text)
                        }
                    }
                }

                if !parsed.todoTexts.isEmpty {
                    actionItemsSection(parsed.todoTexts)
                }

                if !parsed.risks.isEmpty {
                    parsedSection("Risks & blockers", systemImage: "exclamationmark.triangle.fill") {
                        ForEach(Array(parsed.risks.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "exclamationmark.triangle.fill", color: Color.accentWarning, text: text)
                        }
                    }
                }

                if !parsed.followUps.isEmpty {
                    parsedSection("Follow-ups", systemImage: "arrow.turn.down.right") {
                        ForEach(Array(parsed.followUps.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "arrow.turn.down.right", color: Color.textSecondary, text: text)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "sparkles")
            } description: {
                Text("Generate a structured summary from the transcript and notes.")
            } actions: {
                if canSummarize {
                    Button("Summarize") {
                        summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func summaryHero(_ parsed: SummaryResponseParser.ParsedResponse) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack {
                Label("AI Summary", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentSecondary)
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.summary ?? "", forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(GhostButtonStyle())
            }

            renderedMarkdownSummary(parsed.summary)
        }
        .padding(CasaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stateAIGenerated, in: RoundedRectangle(cornerRadius: CasaRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.xl)
                .strokeBorder(Color.accentSecondary.opacity(0.22), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func parsedSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.textTertiary)
                .symbolRenderingMode(.hierarchical)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func bulletRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(color)
            Text(text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actionItemsSection(_ texts: [String]) -> some View {
        let doneCount = texts.filter { isActionItemCompleted($0) }.count

        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack(spacing: CasaSpace.xs) {
                Label("Action items", systemImage: "checklist")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textTertiary)
                    .symbolRenderingMode(.hierarchical)

                Text("· \(doneCount) of \(texts.count) done")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                let completed = isActionItemCompleted(text)
                HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                    Button {
                        toggleActionItem(text)
                    } label: {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(completed ? Color.accentSuccess : Color.textTertiary)
                    }
                    .buttonStyle(.borderless)

                    Text(text)
                        .font(.body)
                        .strikethrough(completed)
                        .foregroundStyle(completed ? Color.textTertiary : Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transcript tab

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack {
                Label("Transcript", systemImage: "doc.text")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                if let transcript = meeting.transcript, !transcript.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if canReapplyTerminology {
                    Button {
                        Task { await reapplyTerminology() }
                    } label: {
                        Label("Re-apply terminology", systemImage: "wand.and.sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(terminologyService.isCorrecting)
                }

                if meeting.rawTranscript != nil {
                    Button {
                        restoreOriginalTranscript()
                    } label: {
                        Label("Restore original", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(terminologyService.isCorrecting)
                    .help("Replace the displayed transcript with the unmodified text from the recording, discarding any terminology corrections.")
                }
            }

            if let warning = terminologyService.warningMessage {
                    HStack(alignment: .top, spacing: CasaSpace.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.accentWarning)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            terminologyService.clearWarning()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(CasaSpace.sm)
                    .background(Color.accentWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                if let transcript = meeting.transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(transcript)
                            .font(.body)
                            .foregroundStyle(Color.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(4)
                    }
                    .frame(maxHeight: 280)
                } else {
                    ContentUnavailableView {
                        Label("No Transcript Yet", systemImage: "waveform")
                    } description: {
                        Text("Transcribe the saved recording to review searchable text.")
                    } actions: {
                        if recordingURL != nil {
                            Button("Transcribe") {
                                onTranscribe()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

    // MARK: - Notes tab

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack {
                Label("Notes", systemImage: "pencil.line")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)

                    Spacer()

                    Button {
                        isEditingNotes.toggle()
                    } label: {
                        Label(
                            isEditingNotes ? "Done" : "Edit",
                            systemImage: isEditingNotes ? "checkmark" : "pencil"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if isEditingNotes {
                    VStack(spacing: 0) {
                        ToastMarkdownEditor(
                            text: $meeting.userNotes,
                            placeholder: "Capture decisions, follow-ups, and context..."
                        )
                        .frame(minHeight: 160)
                        .onChange(of: meeting.userNotes) {
                            debouncedSave()
                        }
                    }
                    .padding(CasaSpace.sm)
                    .background(Color.backgroundHover)
                    .clipShape(RoundedRectangle(cornerRadius: CasaRadius.md))
                } else if !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(meeting.userNotes)
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                } else {
                    ContentUnavailableView {
                        Label("No Freeform Notes Yet", systemImage: "text.alignleft")
                    } description: {
                        Text("Use freeform notes for ideas, follow-ups, and context that do not need timestamps.")
                    } actions: {
                        Button("Edit Notes") {
                            isEditingNotes = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        if meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           recordingURL != nil {
            return .transcribe
        }

        if meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           canSummarize {
            return .summarize
        }

        if canExport {
            return .export
        }

        return nil
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

    private func restoreOriginalTranscript() {
        guard let raw = meeting.rawTranscript else { return }
        meeting.transcript = raw
        terminologyService.clearWarning()
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

    // MARK: - Action item ↔ todo sync

    /// Finds the meeting-scoped `TodoItem` whose text matches a parsed action item.
    private func matchingTodo(for text: String) -> TodoItem? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return meeting.todos.first {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }
    }

    private func isActionItemCompleted(_ text: String) -> Bool {
        matchingTodo(for: text)?.isCompleted ?? false
    }

    /// Toggles a parsed action item's completion through the existing
    /// `ObsidianTodoSyncService` flow. If a meeting `TodoItem` already exists for
    /// the text, its `isCompleted` is flipped; otherwise a new completed todo is
    /// created (a check on a not-yet-tracked item).
    private func toggleActionItem(_ text: String) {
        if let todo = matchingTodo(for: text) {
            try? ObsidianTodoSyncService.setCompleted(
                !todo.isCompleted,
                for: todo,
                in: modelContext
            )
        } else {
            try? ObsidianTodoSyncService.createMeetingTodo(
                text: text,
                meeting: meeting,
                in: modelContext
            )
            if let created = matchingTodo(for: text) {
                try? ObsidianTodoSyncService.setCompleted(true, for: created, in: modelContext)
            }
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                recordingInspectorSection

                if !meeting.participants.isEmpty {
                    participantsInspectorSection
                }

                exportInspectorSection
            }
            .padding(CasaSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundSecondary)
    }

    @ViewBuilder
    private var recordingInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Recording")

            if recordingURL != nil {
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved locally")
                            .font(.subheadline)
                            .foregroundStyle(Color.textPrimary)
                        if let duration = meeting.recordingDuration {
                            Text(duration.formattedRecordingDuration)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(CasaSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))

                // NOTE: A full inline audio player (waveform + scrubber) is deferred
                // to a later polish pass; "Show in Finder" is available in the ⋯ menu.
            } else {
                Text("No recording saved for this meeting.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var participantsInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Participants")

            ForEach(Array(meeting.participants.enumerated()), id: \.offset) { _, name in
                HStack(spacing: CasaSpace.sm) {
                    Text(initials(for: name))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.backgroundTertiary, in: Circle())
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var exportInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Export")

            if meeting.appleNotesSummaryNoteID != nil || meeting.appleNotesRawNotesNoteID != nil {
                Label("Exported to Apple Notes", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentSuccess)
                    .symbolRenderingMode(.hierarchical)
            } else if canExport {
                Text("Not exported yet. Use the Export action to save to your configured destination.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("Generate a summary or transcript to enable export.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func inspectorLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Color.textTertiary)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
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

    private func presentExportAlert(title: String, message: String, exportedURLs: [URL]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message

        if exportedURLs.isEmpty {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(exportedURLs)
        }
    }

    @ViewBuilder
    private func renderedMarkdownSummary(_ summary: String) -> some View {
        let rendered = MarkdownConverter.markdownToAttributedString(
            summary,
            baseFont: .systemFont(ofSize: NSFont.systemFontSize)
        )

        if !rendered.string.isEmpty {
            let attributed = AttributedString(rendered)
            Text(attributed)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(summary)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }
}

private enum ReviewPrimaryAction: Equatable {
    case transcribe
    case summarize
    case export
}

private extension TimeInterval {
    var formattedRecordingDuration: String {
        let totalSeconds = max(Int(rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }
}
