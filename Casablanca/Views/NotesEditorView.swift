import AppKit
import SwiftUI
import SwiftData

struct NotesEditorView: View {
    @Bindable var meeting: Meeting
    let onStartRecording: () -> Void
    let onBack: () -> Void

    @State private var saveTask: Task<Void, Never>?
    @State private var editorCoordinator: MarkdownTextEditorCoordinator?
    @State private var exportMessage: String?
    @State private var exportError: String?
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

                if ObsidianExportService.isAvailable {
                    Button {
                        exportToObsidian()
                    } label: {
                        Label("Export to Obsidian", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && meeting.timestampedNotes.isEmpty)
                }
            }
            .padding(CasaSpace.lg)
        }
        .background(Color.backgroundPrimary)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
        .navigationTitle("\(meeting.title) · \(meeting.formattedTime)")
        .alert("Exported to Obsidian", isPresented: exportSuccessBinding) {
            Button("OK", role: .cancel) { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
        .alert("Export Error", isPresented: exportErrorBinding) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var previousNotesBar: some View {
        HStack(spacing: CasaSpace.sm) {
            Image(systemName: "clock")
                .foregroundStyle(Color.accentPrimary)

            Text("\(meeting.timestampedNotes.count) timestamped notes from recording")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            Spacer()
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.sm)
        .background(Color.accentPrimary.opacity(0.05))
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func exportToObsidian() {
        save()
        do {
            let notesURL = try ObsidianExportService.exportRawNotes(meeting: meeting)
            exportMessage = "Notes exported to:\n\(notesURL.lastPathComponent)"
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var exportSuccessBinding: Binding<Bool> {
        Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private func save() {
        try? modelContext.save()
    }
}
