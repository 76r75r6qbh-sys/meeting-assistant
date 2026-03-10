import AppKit
import SwiftUI

struct RecordedMeetingView: View {
    @Bindable var meeting: Meeting
    let onRecordAgain: () -> Void
    let onTranscribe: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var summarizationService = SummarizationService()
    @State private var showingTranscript = false
    @State private var showingNotes = true
    @State private var isEditingNotes = false
    @State private var newNoteText = ""
    @State private var editorCoordinator: MarkdownTextEditorCoordinator?
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerAutomaticSummary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                statusCard
                metadataCard
                summaryCard
                transcriptCard
                timestampedNotesCard
                freeformNotesCard
                languageAndActions

                Spacer(minLength: 0)
            }
            .padding(CasaSpace.xl)
        }
        .frame(maxWidth: CasaLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("\(meeting.title) \u{00B7} \(meeting.transcript != nil ? "Transcribed" : "Saved")")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if meeting.transcript == nil && meeting.recordingFileURL != nil {
                    Button(action: onTranscribe) {
                        Label("Transcribe", systemImage: "waveform")
                    }
                }

                Button {
                    exportMeeting()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!canExport)
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

    // MARK: - Status Card

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                Label("Recording Saved", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentSuccess)

                if meeting.transcript != nil {
                    Text("Meeting has been recorded and transcribed.")
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    Text("The meeting audio is stored locally and ready for transcription.")
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metadata

    private var metadataCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                LabeledContent("Meeting", value: meeting.title)
                LabeledContent("Scheduled", value: meeting.formattedTime)

                if let duration = meeting.recordingDuration {
                    LabeledContent("Recorded", value: duration.formattedRecordingDuration)
                }

                if let recordingPath = meeting.recordingFileURL {
                    LabeledContent("File") {
                        Text(recordingPath)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Transcript Card

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

                if meeting.summary?.isEmpty == false {
                    Button {
                        Task {
                            await summarizeMeeting()
                        }
                    } label: {
                        Label("Regenerate", systemImage: summarizationService.isSummarizing ? "hourglass" : "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canSummarize || summarizationService.isSummarizing)
                } else {
                    Button {
                        Task {
                            await summarizeMeeting()
                        }
                    } label: {
                        Label("Summarize", systemImage: summarizationService.isSummarizing ? "hourglass" : "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSummarize || summarizationService.isSummarizing)
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
                Text("Generate a structured summary from the transcript and notes. The prompt can be adjusted in Settings.")
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptCard: some View {
        if let transcript = meeting.transcript {
            GroupBox {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                HStack {
                    Label("Transcript", systemImage: "doc.text")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)

                    Spacer()

                    Button {
                        showingTranscript.toggle()
                    } label: {
                        Label(
                            showingTranscript ? "Collapse" : "Expand",
                            systemImage: showingTranscript ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if showingTranscript {
                    Text(transcript)
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                } else {
                    let preview = transcript.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
                    Text(preview + (transcript.contains("\n") ? "\n..." : ""))
                        .font(.body)
                        .foregroundStyle(Color.textTertiary)
                        .lineSpacing(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Timestamped Notes Card

    @ViewBuilder
    private var timestampedNotesCard: some View {
        if !meeting.timestampedNotes.isEmpty {
            GroupBox {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                HStack {
                    Label("Meeting Notes", systemImage: "clock")
                        .font(.headline)

                    Text("\(meeting.timestampedNotes.count)")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                        .padding(.horizontal, CasaSpace.xs)
                        .padding(.vertical, CasaSpace.xxs)
                        .background(Color.backgroundHover)
                        .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))

                    Spacer()

                    Button {
                        showingNotes.toggle()
                    } label: {
                        Label(
                            showingNotes ? "Collapse" : "Expand",
                            systemImage: showingNotes ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())

                    Button {
                        copyTimestampedNotes()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if showingNotes {
                    VStack(alignment: .leading, spacing: CasaSpace.xs) {
                        ForEach(meeting.timestampedNotes) { note in
                            HStack(alignment: .top, spacing: CasaSpace.sm) {
                                Text(note.formattedTimestamp)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, CasaSpace.xs)
                                    .padding(.vertical, CasaSpace.xxs)
                                    .background(Color.accentColor.opacity(0.1))
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

                    // Add note inline
                    HStack(spacing: CasaSpace.sm) {
                        TextField("Add a note...", text: $newNoteText)
                            .textFieldStyle(.plain)
                            .font(.body)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Freeform Notes Card

    @ViewBuilder
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
                    .frame(minHeight: 120)
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
                Text("No freeform notes. Click Edit to add some.")
                    .font(.body)
                    .foregroundStyle(Color.textTertiary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Language & Actions

    private var languageAndActions: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            if meeting.transcript == nil && meeting.recordingFileURL != nil {
                HStack(spacing: CasaSpace.md) {
                    Text("Language")
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                    Picker("", selection: $meeting.transcriptionLanguage) {
                        ForEach(TranscriptionService.supportedLanguages, id: \.id) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            HStack(spacing: CasaSpace.sm) {
                if meeting.transcript == nil && meeting.recordingFileURL != nil {
                    Button(action: onTranscribe) {
                        Label("Transcribe", systemImage: "waveform")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                if meeting.transcript != nil || hasNotes {
                    Button {
                        Task {
                            await summarizeMeeting()
                        }
                    } label: {
                        Label(meeting.summary == nil ? "Summarize" : "Refresh Summary", systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canSummarize || summarizationService.isSummarizing)
                }

                Button {
                    exportMeeting()
                } label: {
                    Label("Export to Obsidian", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!canExport)

                if meeting.transcript != nil {
                    Button(action: onRecordAgain) {
                        Label("Record Again", systemImage: "record.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(action: onRecordAgain) {
                        Label("Record Again", systemImage: "record.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                if let url = meeting.recordingFileURL.map(URL.init(fileURLWithPath:)) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: - Helpers

    private func addNote() {
        let trimmed = newNoteText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Use recording duration as the timestamp context for post-recording notes
        let timestamp = meeting.recordingDuration ?? 0
        let note = TimestampedNote(timestamp: timestamp, text: trimmed)
        meeting.timestampedNotes.append(note)
        newNoteText = ""
        save()
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
              UserDefaults.standard.bool(forKey: AppPreferenceKey.autoSummarizeAfterTranscription),
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
