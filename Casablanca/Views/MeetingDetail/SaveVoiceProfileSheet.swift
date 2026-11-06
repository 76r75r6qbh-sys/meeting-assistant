import SwiftUI

/// The "Remember voice…" sheet's state: consent, the running save, and its
/// cancellation. Save needs consent; Cancel works while saving and cancels
/// the analysis.
@MainActor
final class SaveVoiceProfileModel: ObservableObject {
    @Published var consentGiven = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    /// Samples already saved under this name, if a profile exists.
    @Published private(set) var existingSampleCount: Int?

    private let onSave: @MainActor (_ consentGiven: Bool) async throws -> Void
    private var task: Task<Void, Never>?

    init(onSave: @escaping @MainActor (_ consentGiven: Bool) async throws -> Void) {
        self.onSave = onSave
    }

    var canSave: Bool { consentGiven && !isSaving }

    func setExistingSampleCount(_ count: Int?) {
        existingSampleCount = count
    }

    /// Starts the save; `onSuccess` runs only when it finished uncancelled.
    func save(onSuccess: @escaping @MainActor () -> Void) {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let consent = consentGiven
        task = Task { [weak self, onSave] in
            do {
                try await onSave(consent)
                guard !Task.isCancelled else { return }
                self?.isSaving = false
                onSuccess()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.isSaving = false
                self?.errorMessage = "The voice could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Stops a running save (the analysis is cancelled, nothing is saved).
    func cancel() {
        task?.cancel()
        task = nil
        isSaving = false
    }
}

/// "Remember voice…": saves a confirmed speaker's voice as a profile, only
/// after the user confirms the person's explicit consent. Save stays disabled
/// until the consent box is ticked; Cancel (or closing the sheet) stops a
/// running analysis.
struct SaveVoiceProfileSheet: View {
    let speakerName: String
    /// Samples already saved under this name, or nil for a new profile.
    let loadExistingSampleCount: @MainActor () async -> Int?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SaveVoiceProfileModel

    static let consentLabel = "This person gave explicit consent"

    init(
        speakerName: String,
        loadExistingSampleCount: @escaping @MainActor () async -> Int? = { nil },
        onSave: @escaping @MainActor (_ consentGiven: Bool) async throws -> Void
    ) {
        self.speakerName = speakerName
        self.loadExistingSampleCount = loadExistingSampleCount
        _model = StateObject(wrappedValue: SaveVoiceProfileModel(onSave: onSave))
    }

    static func existingProfileNote(name: String, sampleCount: Int) -> String {
        "Adds a sample to \(name) (\(sampleCount) \(sampleCount == 1 ? "sample" : "samples"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            Text("Remember the voice of \u{201C}\(speakerName)\u{201D}")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if let count = model.existingSampleCount {
                Text(Self.existingProfileNote(name: speakerName, sampleCount: count))
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Text(PrivacySettingsSection.explanation)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(Self.consentLabel, isOn: $model.consentGiven)
                .toggleStyle(.checkbox)
                .disabled(model.isSaving)

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: CasaSpace.sm) {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Analysing voice\u{2026}")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
                Spacer()
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { model.save { dismiss() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
        .padding(CasaSpace.lg)
        .frame(width: 420)
        .task { model.setExistingSampleCount(await loadExistingSampleCount()) }
        .onDisappear { model.cancel() }
    }
}
