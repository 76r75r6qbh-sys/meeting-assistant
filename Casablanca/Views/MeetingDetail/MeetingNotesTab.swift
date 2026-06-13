import SwiftUI

struct MeetingNotesTab: View {
    @Bindable var meeting: Meeting
    /// Owned by the long-lived parent so the Edit/read toggle survives leaving
    /// and returning to the Notes tab.
    @Binding var isEditingNotes: Bool
    /// Parent-owned debounced save. Owning the underlying `Task` on the parent
    /// keeps a pending save alive when this subview is torn down on tab switch.
    let onNotesEdited: () -> Void

    var body: some View {
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
                        onNotesEdited()
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
