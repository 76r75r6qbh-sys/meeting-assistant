import AppKit
import SwiftUI

struct RecordedMeetingView: View {
    @Bindable var meeting: Meeting
    let onRecordAgain: () -> Void
    let onTranscribe: () -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.autoSummarizeAfterTranscription) private var autoSummarizeAfterTranscription = false
    @AppStorage(AppPreferenceKey.autoExportNotesToObsidian) private var autoExportNotesToObsidian = false
    @Environment(AppModel.self) private var appModel
    private var summarizationService: SummarizationService { appModel.summarizationService }
    private var terminologyService: TerminologyService { appModel.terminologyService }
    @State private var isEditingNotes = false
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerAutomaticSummary = false
    @State private var pendingReview: PendingTodoReview?
    @State private var pendingTodoTexts: [String] = []

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                contentLayout(for: proxy.size.width)
                    .padding(CasaSpace.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let primaryToolbarAction {
                    toolbarButton(for: primaryToolbarAction, isPrimary: true)
                }

                if primaryToolbarAction != .export, canExport {
                    toolbarButton(for: .export, isPrimary: false)
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
        .sheet(item: $pendingReview) { review in
            TodoReviewSheet(
                meetingTitle: meeting.title,
                summary: review.summary,
                todoTexts: $pendingTodoTexts,
                onSave: {
                    saveTodos(texts: pendingTodoTexts)
                    pendingReview = nil
                },
                onDiscard: {
                    pendingReview = nil
                    save()
                }
            )
            .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private func contentLayout(for width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxl) {
            infoBar

            if shouldShowPipelineBanner {
                pipelineBanner
            }

            if usesTwoColumnLayout(for: width) {
                HStack(alignment: .top, spacing: CasaSpace.xl) {
                    VStack(alignment: .leading, spacing: CasaSpace.xxl) {
                        summaryCard
                        transcriptCard
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: CasaSpace.xxl) {
                        freeformNotesCard
                    }
                    .frame(width: notesColumnWidth(for: width), alignment: .topLeading)
                }
                actionItemsCard
            } else {
                summaryCard
                transcriptCard
                freeformNotesCard
                actionItemsCard
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
                if summarizationService.isSummarizing || terminologyService.isCorrecting {
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

    private var summaryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                HStack {
                    Label("Summary", systemImage: "sparkles")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)

                    Spacer()

                    if let summary = meeting.summary, !summary.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }

                if summarizationService.isSummarizing {
                    HStack(spacing: CasaSpace.sm) {
                        ProgressView()
                            .controlSize(.small)

                        Text(summarizationService.statusMessage.isEmpty ? "Generating summary..." : summarizationService.statusMessage)
                            .font(.body)
                            .foregroundStyle(Color.textSecondary)
                    }
                } else if let summary = meeting.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    renderedMarkdownSummary(summary)
                } else {
                    ContentUnavailableView {
                        Label("No Summary Yet", systemImage: "sparkles")
                    } description: {
                        Text("Generate a structured summary from the transcript and notes.")
                    } actions: {
                        if canSummarize {
                            Button("Summarize") {
                                Task {
                                    await summarizeMeeting()
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcriptCard: some View {
        GroupBox {
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
    }

    private var freeformNotesCard: some View {
        GroupBox {
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

                if !meeting.timestampedNotes.isEmpty {
                    Divider()

                    TimestampedNotesHistorySection(notes: meeting.timestampedNotes)
                }
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
                Task {
                    await summarizeMeeting()
                }
            } label: {
                Label("Summarize", systemImage: summarizationService.isSummarizing ? "hourglass" : "sparkles")
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
        !meeting.timestampedNotes.isEmpty || !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var shouldShowPipelineBanner: Bool {
        terminologyService.isCorrecting
            || summarizationService.isSummarizing
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

        if summarizationService.isSummarizing {
            return summarizationService.statusMessage.isEmpty ? "Generating summary..." : summarizationService.statusMessage
        }

        if autoSummarizeAfterTranscription && autoExportNotesToObsidian {
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

    private func usesTwoColumnLayout(for width: CGFloat) -> Bool {
        width >= 1040
    }

    private func notesColumnWidth(for width: CGFloat) -> CGFloat {
        min(max(width * 0.34, 320), 420)
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

    private func summarizeMeeting() async {
        do {
            let parsed = try await summarizationService.summarize(meeting: meeting)
            meeting.summary = parsed.summary
            if !parsed.todoTexts.isEmpty {
                pendingTodoTexts = parsed.todoTexts
                pendingReview = PendingTodoReview(
                    meetingID: meeting.id,
                    summary: parsed.summary,
                    todoTexts: parsed.todoTexts
                )
            } else {
                save()
            }
        } catch {
            summarizationService.errorMessage = error.localizedDescription
        }
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

        do {
            let result = try ExportService.exportCompletedMeeting(meeting)
            let message: String
            if result.summaryURL != nil {
                message = "Saved the summary note and raw notes to your Obsidian meeting notes folder."
            } else {
                message = "Saved raw notes to Obsidian. Generate a summary and export again to add the summary note."
            }

            presentExportAlert(
                title: "Export Complete",
                message: message,
                exportedURLs: result.exportedURLs
            )
        } catch {
            presentExportAlert(
                title: "Export Failed",
                message: error.localizedDescription,
                exportedURLs: []
            )
        }
    }

    private func saveTodos(texts: [String]) {
        for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? ObsidianTodoSyncService.createMeetingTodo(
                text: text,
                meeting: meeting,
                in: modelContext
            )
        }
    }

    @ViewBuilder
    private var actionItemsCard: some View {
        if !meeting.todos.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: CasaSpace.md) {
                    Label("Action Items", systemImage: "checklist")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)

                    ForEach(meeting.todos.sorted(by: { $0.createdAt < $1.createdAt })) { todo in
                        HStack(spacing: CasaSpace.sm) {
                            Button {
                                try? ObsidianTodoSyncService.setCompleted(
                                    !todo.isCompleted,
                                    for: todo,
                                    in: modelContext
                                )
                            } label: {
                                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(todo.isCompleted ? Color.accentSuccess : Color.textTertiary)
                            }
                            .buttonStyle(.borderless)

                            Text(todo.text)
                                .strikethrough(todo.isCompleted)
                                .foregroundStyle(todo.isCompleted ? Color.textTertiary : Color.textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func save() {
        try? modelContext.save()
        ExportService.exportAutomaticallyIfEnabled(meeting)
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
        await summarizeMeeting()
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
