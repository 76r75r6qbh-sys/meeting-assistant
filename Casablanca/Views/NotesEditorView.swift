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
                    save()
                } label: {
                    Label("Save & Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && meeting.timestampedNotes.isEmpty)
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

    private func save() {
        try? modelContext.save()
    }
}
