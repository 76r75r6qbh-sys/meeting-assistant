import SwiftUI
import SwiftData

struct NotesEditorView: View {
    @Bindable var meeting: Meeting
    let onStartRecording: () -> Void
    let onBack: () -> Void

    @State private var saveTask: Task<Void, Never>?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            // Notes editor - full height
            TextEditor(text: $meeting.userNotes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(CasaSpace.lg)
                .onChange(of: meeting.userNotes) {
                    debouncedSave()
                }

            Divider()

            // Bottom bar with actions
            HStack {
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
                .disabled(meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        .navigationTitle("\(meeting.title) \u{00B7} \(meeting.formattedTime)")
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
