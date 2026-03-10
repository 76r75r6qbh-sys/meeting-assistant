import AppKit
import SwiftUI

struct RecordedMeetingView: View {
    @Bindable var meeting: Meeting
    let onRecordAgain: () -> Void
    let onTranscribe: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showingTranscript = false
    @State private var showingNotes = true
    @State private var isEditingNotes = false
    @State private var newNoteText = ""
    @State private var editorCoordinator: MarkdownTextEditorCoordinator?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                statusCard
                metadataCard
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
    }

    // MARK: - Status Card

    private var statusCard: some View {
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
        .cardStyle()
    }

    // MARK: - Metadata Card

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            metadataRow(title: "Meeting", value: meeting.title)
            metadataRow(title: "Scheduled", value: meeting.formattedTime)

            if let duration = meeting.recordingDuration {
                metadataRow(title: "Recorded", value: duration.formattedRecordingDuration)
            }

            if let recordingPath = meeting.recordingFileURL {
                metadataRow(title: "File", value: recordingPath)
            }
        }
        .cardStyle()
    }

    // MARK: - Transcript Card

    @ViewBuilder
    private var transcriptCard: some View {
        if let transcript = meeting.transcript {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                HStack {
                    Label("Transcript", systemImage: "doc.text")
                        .font(.headline)

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
            .cardStyle()
        }
    }

    // MARK: - Timestamped Notes Card

    @ViewBuilder
    private var timestampedNotesCard: some View {
        if !meeting.timestampedNotes.isEmpty {
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
                                    .foregroundStyle(Color.accentPrimary)
                                    .padding(.horizontal, CasaSpace.xs)
                                    .padding(.vertical, CasaSpace.xxs)
                                    .background(Color.accentPrimary.opacity(0.1))
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
                                    ? Color.textTertiary : Color.accentPrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(newNoteText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(CasaSpace.sm)
                    .background(Color.backgroundHover)
                    .clipShape(RoundedRectangle(cornerRadius: CasaRadius.md))
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Freeform Notes Card

    @ViewBuilder
    private var freeformNotesCard: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack {
                Label("Notes", systemImage: "pencil.line")
                    .font(.headline)

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
                        save()
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
        .cardStyle()
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
                .cardStyle()
            }

            HStack(spacing: CasaSpace.sm) {
                if meeting.transcript == nil && meeting.recordingFileURL != nil {
                    Button(action: onTranscribe) {
                        Label("Transcribe", systemImage: "waveform")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

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

    private func save() {
        try? modelContext.save()
    }

    private func metadataRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(Color.textTertiary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
        }
        .font(.body)
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
