import SwiftUI

/// Compact chip exposing the current input device + transcription language, with
/// a popover for switching microphone, toggling system-audio capture, and
/// choosing the transcription language. Used in both the recording status bar
/// and the notes-state footer.
struct DeviceLanguageChip: View {
    @Bindable var recordingService: AudioRecordingService
    @Binding var transcriptionLanguage: String
    let onLanguageChanged: () -> Void

    @State private var showingQuickControl = false

    private var selectedDeviceName: String {
        recordingService.availableInputDevices
            .first(where: { $0.id == recordingService.selectedInputDeviceID })?
            .name ?? "No microphone"
    }

    private var selectedLanguageShortLabel: String {
        let id = transcriptionLanguage
        switch id {
        case "en-US": return "EN-US"
        case "en-GB": return "EN-GB"
        case "nl-NL": return "NL"
        default:
            // Fall back to the language subtag of a BCP-47 id, uppercased.
            let primary = id.split(separator: "-").first.map(String.init) ?? id
            return primary.uppercased()
        }
    }

    var body: some View {
        Button {
            showingQuickControl.toggle()
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                Text("\(selectedDeviceName) · \(selectedLanguageShortLabel)")
                    .font(.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, CasaSpace.md)
            .padding(.vertical, CasaSpace.xs)
            .background(Color.backgroundActive, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: CasaRadius.lg)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording device and language")
        .accessibilityValue("\(selectedDeviceName), \(selectedLanguageShortLabel)")
        .popover(isPresented: $showingQuickControl, arrowEdge: .bottom) {
            popover
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Input device")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, CasaSpace.sm)
                .padding(.bottom, CasaSpace.xs)

            if recordingService.availableInputDevices.isEmpty {
                Text("No microphone found")
                    .font(.body)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, CasaSpace.sm)
                    .padding(.vertical, CasaSpace.xs)
            } else {
                ForEach(recordingService.availableInputDevices) { device in
                    deviceRow(device)
                }
            }

            Toggle(isOn: Binding(
                get: { recordingService.isSystemAudioEnabled },
                set: { newValue in
                    if newValue != recordingService.isSystemAudioEnabled {
                        recordingService.toggleSystemAudioEnabled()
                    }
                }
            )) {
                Label("Also capture system audio", systemImage: "speaker.wave.2.fill")
                    .font(.body)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(recordingService.isPreparing)
            .padding(.horizontal, CasaSpace.sm)
            .padding(.top, CasaSpace.xs)

            Divider()
                .padding(.vertical, CasaSpace.md)

            Text("Transcription language")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, CasaSpace.sm)
                .padding(.bottom, CasaSpace.xs)

            ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
                languageRow(id: language.id, name: language.name)
            }

            Divider()
                .padding(.vertical, CasaSpace.md)

            SettingsLink {
                Label("Recording defaults in Settings…", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, CasaSpace.sm)
        }
        .padding(CasaSpace.md)
        .frame(width: CasaLayout.popoverWidth)
    }

    @ViewBuilder
    private func deviceRow(_ device: AudioInputDevice) -> some View {
        let isSelected = device.id == recordingService.selectedInputDeviceID

        Button {
            guard !isSelected else { return }
            Task { await recordingService.selectInputDevice(device.id) }
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.textSecondary)
                    .frame(width: 16)

                Text(device.name)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: CasaSpace.sm)

                if isSelected {
                    AudioLevelMeterView(level: recordingService.audioLevel)
                        .frame(height: 14)
                }
            }
            .padding(.horizontal, CasaSpace.sm)
            .padding(.vertical, CasaSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recordingService.isPreparing)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func languageRow(id: String, name: String) -> some View {
        let isSelected = id == transcriptionLanguage

        Button {
            guard !isSelected else { return }
            transcriptionLanguage = id
            onLanguageChanged()
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: CasaSpace.sm)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, CasaSpace.sm)
            .padding(.vertical, CasaSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
