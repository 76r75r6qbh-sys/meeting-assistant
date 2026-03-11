import AppKit
import SwiftUI
import SwiftData

struct NotesEditorView: View {
    @Bindable var meeting: Meeting
    let onStartRecording: () -> Void
    let onBack: () -> Void

    @State private var saveTask: Task<Void, Never>?
    @State private var editorCoordinator: MarkdownTextEditorCoordinator?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            // Timestamped notes summary (if any exist from a previous recording)
            if !meeting.timestampedNotes.isEmpty {
                previousNotesBar
                Divider()
            }

            // Formatting toolbar
            MarkdownFormattingToolbar(coordinator: editorCoordinator)
            Divider()

            // Markdown-aware notes editor
            MarkdownTextEditor(
                text: $meeting.userNotes,
                font: .systemFont(ofSize: NSFont.systemFontSize),
                coordinator: $editorCoordinator
            )
            .padding(CasaSpace.lg)
            .onChange(of: meeting.userNotes) {
                debouncedSave()
            }

            Divider()

            // Bottom bar with actions
            HStack {
                HStack(spacing: CasaSpace.sm) {
                    Text("Language")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    Picker("Language", selection: $meeting.transcriptionLanguage) {
                        ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .onChange(of: meeting.transcriptionLanguage) {
                        save()
                    }
                }

                Button(action: onStartRecording) {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())

                Spacer()

                Button {
                    exportNotes()
                } label: {
                    Label("Save & Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && meeting.timestampedNotes.isEmpty)
            }
            .padding(CasaSpace.lg)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
        .navigationTitle("\(meeting.title) · \(meeting.formattedTime)")
    }

    private var previousNotesBar: some View {
        HStack(spacing: CasaSpace.sm) {
            Image(systemName: "clock")
                .foregroundStyle(Color.accentColor)

            Text("\(meeting.timestampedNotes.count) timestamped notes from recording")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            Spacer()
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.sm)
        .background(Color.accentColor.opacity(0.05))
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        try? modelContext.save()
        ExportService.exportAutomaticallyIfEnabled(meeting)
    }

    private func exportNotes() {
        save()

        do {
            let result = try ExportService.exportRawNotes(meeting)
            presentExportAlert(
                title: "Export Complete",
                message: "Saved raw notes to your Obsidian meeting notes folder.",
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
}
