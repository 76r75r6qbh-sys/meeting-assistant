import SwiftUI

/// Settings → Recording → Speakers: the speaker toggles, the diarization
/// model's state with a "Download now" button, and the licence footer.
struct SpeakerSettingsSection: View {
    @AppStorage(AppPreferenceKey.recogniseSpeakersEnabled) private var recogniseSpeakersEnabled = true
    @AppStorage(AppPreferenceKey.keepSpeakerTracks) private var keepSpeakerTracks = true
    @AppStorage(AppPreferenceKey.wordTimestampsEnabled) private var wordTimestampsEnabled = true
    @AppStorage(AppPreferenceKey.suggestSpeakerNamesAutomatically) private var suggestNamesAutomatically = false

    @State private var modelStatus = SpeakerModelStatus.shared
    var diarizer: SpeakerDiarizing = FluidAudioDiarizer.shared

    var body: some View {
        Section {
            Toggle("Recognise speakers", isOn: $recogniseSpeakersEnabled)
            Toggle("Keep separate speaker tracks", isOn: $keepSpeakerTracks)
            Toggle("Word timestamps", isOn: $wordTimestampsEnabled)
            Toggle(isOn: $suggestNamesAutomatically) {
                Text("Suggest speaker names automatically")
                Text("After each transcription, sends the participants and the first 10 minutes to your AI provider. Names are only suggested; you confirm each one.")
            }
            modelRow
        } header: {
            Text("Speakers")
        } footer: {
            Text(Self.licenceFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        LabeledContent("Speaker model") {
            HStack(spacing: 8) {
                switch modelStatus.state {
                case .notDownloaded:
                    Text("Not downloaded").foregroundStyle(.secondary)
                    downloadButton
                case .downloading(let fraction):
                    if let fraction {
                        ProgressView(value: min(max(fraction, 0), 1)).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Downloading\u{2026}").foregroundStyle(.secondary)
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(message)
                    downloadButton
                }
            }
        }
        if !FluidAudioDiarizer.isSupportedOS {
            Text("Telling speakers apart needs macOS 15 or later; transcripts label the far end \u{201C}Others\u{201D}.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadButton: some View {
        Button("Download now") {
            Task { try? await modelStatus.prepare(using: diarizer) }
        }
        .disabled(!FluidAudioDiarizer.isSupportedOS)
    }

    static let licenceFooter = """
        Speakers are told apart on this Mac with FluidAudio (Apache-2.0) and the \
        pyannote speaker-diarization-community-1 models (segmentation and WeSpeaker \
        embedding, with PLDA by BUT Speech@FIT), converted to Core ML by Fluid \
        Inference and licensed CC-BY-4.0. About 22 MB, downloaded once from \
        Hugging Face; audio never leaves this Mac.
        """
}
