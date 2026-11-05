import SwiftUI

/// Settings → AI → To-do Review. Phase 0 placeholder; Track B fills it.
struct ActionItemReviewSettingsSection: View {
    @AppStorage(AppPreferenceKey.autoAcceptVerifiedTodos) private var autoAcceptVerifiedTodos = false

    var body: some View {
        Section("To-do Review") {
            Toggle("Auto-accept verified to-dos", isOn: $autoAcceptVerifiedTodos)
        }
    }
}
