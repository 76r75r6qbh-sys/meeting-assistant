import SwiftUI

/// Settings → Recording → Privacy: the opt-in for voice profiles (off by
/// default), what they are, and the saved profiles with a delete per row.
/// Turning the toggle off deletes every profile and the key, after a
/// confirmation; Cancel leaves it on. Deleting a profile, or turning off, also
/// removes the voice-profile suggestions from the meetings' sidecars. Profile
/// I/O runs off the main actor (the keychain may prompt).
struct PrivacySettingsSection: View {
    @AppStorage(AppPreferenceKey.voiceProfilesEnabled) private var voiceProfilesEnabled = false

    var store = VoiceProfileStore()
    var speakerStore = SpeakerAnalysisStore()

    @State private var profiles: [VoiceProfile] = []
    @State private var confirmingTurnOff = false
    @State private var errorMessage: String?

    static let toggleLabel = "Remember voices (biometric data)"
    static let explanation = "Voice profiles are biometric personal data (GDPR/AVG art. 9). Casablanca stores them only on this Mac, encrypted, and only uses them to suggest names. Save a profile only with the person\u{2019}s explicit consent. Using this within an organisation requires a DPIA first."
    static let turnOffMessage = "Turning this off deletes all saved voice profiles."

    var body: some View {
        Section("Privacy") {
            Toggle(isOn: toggleBinding) {
                Text(Self.toggleLabel)
                Text(Self.explanation)
            }

            if voiceProfilesEnabled {
                if profiles.isEmpty {
                    Text("No voice profiles saved. Save one from a named speaker in a meeting (Remember voice\u{2026}).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // Off: nothing to list, and no reason to read the key.
            if voiceProfilesEnabled { await reload() }
        }
        .alert(Self.turnOffMessage, isPresented: $confirmingTurnOff) {
            Button("Delete profiles", role: .destructive) { Task { await turnOff() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func profileRow(_ profile: VoiceProfile) -> some View {
        LabeledContent {
            Button(role: .destructive) {
                Task { await delete(profile) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this voice profile")
            .accessibilityLabel("Delete voice profile of \(profile.name)")
        } label: {
            Text(profile.name)
            Text("Saved \(profile.createdAt.formatted(date: .abbreviated, time: .omitted)) \u{00B7} \(profile.sampleCount) \(profile.sampleCount == 1 ? "sample" : "samples")")
        }
    }

    /// Turning on is immediate; turning off asks first when there is
    /// something to delete.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { voiceProfilesEnabled },
            set: { isOn in
                if isOn {
                    voiceProfilesEnabled = true
                    Task { await reload() }
                } else if FileManager.default.fileExists(atPath: store.fileURL.path) {
                    confirmingTurnOff = true
                } else {
                    Task { await turnOff() }
                }
            }
        )
    }

    private func reload() async {
        let store = self.store
        do {
            profiles = try await Task.detached { try store.all() }.value
            errorMessage = nil
        } catch {
            profiles = []
            errorMessage = "The voice profiles could not be opened: \(error.localizedDescription)"
        }
    }

    private func delete(_ profile: VoiceProfile) async {
        let store = self.store
        let speakerStore = self.speakerStore
        do {
            try await Task.detached {
                try store.delete(id: profile.id)
                speakerStore.removeVoiceProfileSuggestions(naming: profile.name)
            }.value
            await reload()
        } catch {
            errorMessage = "The voice profile could not be deleted: \(error.localizedDescription)"
        }
    }

    /// Switches the feature off first (so a save still running is refused),
    /// then deletes the file, the key and every voice-profile suggestion. If
    /// deleting fails, the toggle goes back on with the error shown.
    private func turnOff() async {
        voiceProfilesEnabled = false
        let store = self.store
        let speakerStore = self.speakerStore
        do {
            try await Task.detached {
                try store.deleteAll()
                speakerStore.removeVoiceProfileSuggestions()
            }.value
            profiles = []
            errorMessage = nil
        } catch {
            voiceProfilesEnabled = true
            errorMessage = "The voice profiles could not be deleted: \(error.localizedDescription)"
        }
    }
}
