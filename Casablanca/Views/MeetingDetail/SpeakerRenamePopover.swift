import SwiftUI

/// Names one speaker: a text field, the meeting's participants as one-tap
/// names, and the LLM's suggestions with their evidence. Nothing is applied
/// without a tap. Room speakers (in-room meetings) can also be marked as the
/// user.
struct SpeakerRenamePopover: View {
    let speaker: SpeakerInfo
    /// Participants not already used as another speaker's name.
    let participants: [String]
    let suggestions: [SpeakerNameSuggestion]
    /// Applies a typed or picked name. Returns an error message to show, or nil.
    let onRename: (String) -> String?
    let onAcceptSuggestion: (SpeakerNameSuggestion) -> String?
    let onSetIsUser: (Bool) -> Void
    let onDone: () -> Void

    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    init(
        speaker: SpeakerInfo,
        participants: [String],
        suggestions: [SpeakerNameSuggestion],
        onRename: @escaping (String) -> String?,
        onAcceptSuggestion: @escaping (SpeakerNameSuggestion) -> String?,
        onSetIsUser: @escaping (Bool) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.speaker = speaker
        self.participants = participants
        self.suggestions = suggestions
        self.onRename = onRename
        self.onAcceptSuggestion = onAcceptSuggestion
        self.onSetIsUser = onSetIsUser
        self.onDone = onDone
        _name = State(initialValue: speaker.nameConfirmed ? speaker.displayName : "")
    }

    private var canSave: Bool {
        !SpeakerRenamer.sanitize(name).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            Text("Name \u{201C}\(speaker.displayName)\u{201D}")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: CasaSpace.sm) {
                TextField("Name", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .accessibilityLabel("Speaker name")
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.accentWarning)
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: CasaSpace.sm) {
                    Text("Suggested from the transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textTertiary)
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                            Button("Use \(suggestion.name)") {
                                apply(onAcceptSuggestion(suggestion))
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityHint("Names this speaker \(suggestion.name)")
                            Text("\u{201C}\(suggestion.evidence)\u{201D}")
                                .font(.caption.italic())
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !participants.isEmpty {
                VStack(alignment: .leading, spacing: CasaSpace.xs) {
                    Text("Participants")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textTertiary)
                    FlowLayout(spacing: CasaSpace.xs) {
                        ForEach(participants, id: \.self) { participant in
                            TagChip(text: participant, onTap: { name = participant; fieldFocused = true })
                                .accessibilityLabel("Use participant \(participant)")
                        }
                    }
                }
            }

            if speaker.source == .room {
                Toggle("This is me", isOn: Binding(
                    get: { speaker.isUser },
                    set: { onSetIsUser($0) }
                ))
                .toggleStyle(.checkbox)
                .help("Marks this voice as yours in this meeting.")
            }
        }
        .padding(CasaSpace.lg)
        .frame(width: CasaLayout.popoverWidth)
        .onAppear { fieldFocused = true }
    }

    private func save() {
        guard canSave else { return }
        apply(onRename(name))
    }

    private func apply(_ error: String?) {
        if let error {
            errorMessage = error
        } else {
            onDone()
        }
    }
}
