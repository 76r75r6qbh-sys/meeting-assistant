import SwiftUI

/// Settings → AI → Summary Templates. Phase 0 placeholder; Track B fills it.
/// `summaryTemplates` holds JSON; empty means only the built-in templates.
struct SummaryTemplatesSettingsSection: View {
    @AppStorage(AppPreferenceKey.summaryTemplates) private var summaryTemplates = ""

    var body: some View {
        Section("Summary Templates") {
            Text(summaryTemplates.isEmpty ? "Using the built-in templates." : "Using customised templates.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }
}
