import SwiftUI

/// Settings → Recording → Privacy. Phase 0 placeholder; Track A fills it.
struct PrivacySettingsSection: View {
    @AppStorage(AppPreferenceKey.voiceProfilesEnabled) private var voiceProfilesEnabled = false

    var body: some View {
        Section("Privacy") {
            Toggle("Remember voices (biometric data)", isOn: $voiceProfilesEnabled)
        }
    }
}
