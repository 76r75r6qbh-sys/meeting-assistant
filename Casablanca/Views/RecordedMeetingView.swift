import AppKit
import SwiftUI

struct RecordedMeetingView: View {
    @Bindable var meeting: Meeting
    let onRecordAgain: () -> Void
    let onTranscribe: () -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.autoSummarizeAfterTranscription) private var autoSummarizeAfterTranscription = false
    @AppStorage(AppPreferenceKey.autoExportNotesToObsidian) private var autoExportNotesToObsidian = false
    @State private var summarizationService = SummarizationService()
    @State private var isEditingNotes = false
    @State private var newNoteText = ""
    @State private var editorCoordinator: MarkdownTextEditorCoordinator?
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerAutomaticSummary = false
    @FocusState private var isNewNoteFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.xxl) {
                infoBar

                if shouldShowPipelineBanner {
                    pipelineBanner
                }

                summaryCard
                transcriptCard
                timestampedNotesCard
                freeformNotesCard

                Spacer(minLength: 0)
            }
            .padding(CasaSpace.xl)
        }
        .frame(maxWidth: CasaLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
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
                .buttonStyle(SecondaryButtonStyle())

                if let recordingURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([recordingURL])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .task(id: meeting.id) {
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
                if summarizationService.isSummarizing {
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

    private var timestampedNotesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                HStack {
                    Label("Meeting Notes", systemImage: "clock")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)

                    if !meeting.timestampedNotes.isEmpty {
                        Text("\(meeting.timestampedNotes.count)")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                            .padding(.horizontal, CasaSpace.xs)
                            .padding(.vertical, CasaSpace.xxs)
                            .background(Color.backgroundHover)
                            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
                    }

                    Spacer()

                    if !meeting.timestampedNotes.isEmpty {
                        Button {
                            copyTimestampedNotes()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }

                if meeting.timestampedNotes.isEmpty {
                    ContentUnavailableView {
                        Label("No Timestamped Notes Yet", systemImage: "clock.badge.questionmark")
                    } description: {
                        Text("Add a quick note to capture a point from the recording.")
                    } actions: {
                        Button("Add Note") {
                            isNewNoteFieldFocused = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    VStack(alignment: .leading, spacing: CasaSpace.xs) {
                        ForEach(meeting.timestampedNotes) { note in
                            HStack(alignment: .top, spacing: CasaSpace.sm) {
                                Text(note.formattedTimestamp)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Color.textSecondary)
                                    .padding(.horizontal, CasaSpace.xs)
                                    .padding(.vertical, CasaSpace.xxs)
                                    .background(Color.backgroundHover)
                                    .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
                                    .frame(minWidth: 52, alignment: .center)

                                Text(note.text)
                                    .font(.body)
                                    .foregroundStyle(Color.textPrimary)
                                    .textSelection(.enabled)

                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, CasaSpace.xxs)
                        }
                    }
                }

                HStack(spacing: CasaSpace.sm) {
                    TextField("Add a note...", text: $newNoteText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($isNewNoteFieldFocused)
                        .onSubmit {
                            addNote()
                        }

                    Button {
                        addNote()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(newNoteText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.textTertiary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newNoteText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(CasaSpace.sm)
                .background(Color.backgroundHover)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.md))
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
                        MarkdownFormattingToolbar(coordinator: editorCoordinator)
                        MarkdownTextEditor(
                            text: $meeting.userNotes,
                            font: .systemFont(ofSize: NSFont.systemFontSize),
                            coordinator: $editorCoordinator
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
    }

    @ViewBuilder
    private func toolbarButton(for action: ReviewPrimaryAction, isPrimary: Bool) -> some View {
        switch action {
        case .transcribe:
            Button(action: onTranscribe) {
                Label("Transcribe", systemImage: "waveform")
            }
            .modifier(ToolbarActionButtonStyle(isPrimary: isPrimary))
        case .summarize:
            Button {
                Task {
                    await summarizeMeeting()
                }
            } label: {
                Label("Summarize", systemImage: summarizationService.isSummarizing ? "hourglass" : "sparkles")
            }
            .modifier(ToolbarActionButtonStyle(isPrimary: isPrimary))
            .disabled(!canSummarize || summarizationService.isSummarizing)
        case .export:
            Button {
                exportMeeting()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .modifier(ToolbarActionButtonStyle(isPrimary: isPrimary))
            .disabled(!canExport)
        }
    }

    private func addNote() {
        let trimmed = newNoteText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let timestamp = meeting.recordingDuration ?? 0
        let note = TimestampedNote(timestamp: timestamp, text: trimmed)
        meeting.timestampedNotes.append(note)
        newNoteText = ""
        save()
        isNewNoteFieldFocused = true
    }

    private func copyTimestampedNotes() {
        let text = meeting.timestampedNotes
            .map { "[\($0.formattedTimestamp)] \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        summarizationService.isSummarizing
            || (autoSummarizeAfterTranscription
                && meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
    }

    private var pipelineStatusText: String {
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
            let summary = try await summarizationService.summarize(meeting: meeting)
            meeting.summary = summary
            save()
        } catch {
            summarizationService.errorMessage = error.localizedDescription
        }
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

private struct ToolbarActionButtonStyle: ViewModifier {
    let isPrimary: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(PrimaryButtonStyle())
        } else {
            content.buttonStyle(SecondaryButtonStyle())
        }
    }
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
