import SwiftUI

/// "Remember voice…": saves a confirmed speaker's voice as a profile, only
/// after the user confirms the person's explicit consent. Save stays disabled
/// until the consent box is ticked.
struct SaveVoiceProfileSheet: View {
    let speakerName: String
    /// Computes the embedding and saves the profile. Throws to show an error.
    let onSave: @MainActor (_ consentGiven: Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var consentGiven = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    static let consentLabel = "This person gave explicit consent"

    static func canSave(consentGiven: Bool, isSaving: Bool) -> Bool {
        consentGiven && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            Text("Remember the voice of \u{201C}\(speakerName)\u{201D}")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(PrivacySettingsSection.explanation)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(Self.consentLabel, isOn: $consentGiven)
                .toggleStyle(.checkbox)
                .disabled(isSaving)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: CasaSpace.sm) {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("Analysing voice\u{2026}")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canSave(consentGiven: consentGiven, isSaving: isSaving))
            }
        }
        .padding(CasaSpace.lg)
        .frame(width: 420)
    }

    private func save() async {
        guard Self.canSave(consentGiven: consentGiven, isSaving: isSaving) else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await onSave(consentGiven)
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            errorMessage = "The voice could not be saved: \(error.localizedDescription)"
        }
    }
}
