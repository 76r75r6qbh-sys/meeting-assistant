import SwiftUI

/// Settings → Recording → Speakers. Phase 0 placeholder; Track A fills it.
struct SpeakerSettingsSection: View {
    @AppStorage(AppPreferenceKey.recogniseSpeakersEnabled) private var recogniseSpeakersEnabled = true
    @AppStorage(AppPreferenceKey.keepSpeakerTracks) private var keepSpeakerTracks = true
    @AppStorage(AppPreferenceKey.wordTimestampsEnabled) private var wordTimestampsEnabled = true

    var body: some View {
        Section("Speakers") {
            Toggle("Recognise speakers", isOn: $recogniseSpeakersEnabled)
            Toggle("Keep separate speaker tracks", isOn: $keepSpeakerTracks)
            Toggle("Word timestamps", isOn: $wordTimestampsEnabled)
        }
    }
}
