import AppKit
import SwiftUI

/// Settings → AI → To-do Review: auto-accept for verified to-dos and the
/// decision log (`TodoDecisionLog`).
struct ActionItemReviewSettingsSection: View {
    @AppStorage(AppPreferenceKey.autoAcceptVerifiedTodos) private var autoAcceptVerifiedTodos = false
    /// Checked when the section appears; the log is created on the first decision.
    @State private var decisionLogExists = false

    private let decisionLogURL = TodoDecisionLog.shared.fileURL

    var body: some View {
        Section("To-do Review") {
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Toggle("Auto-accept verified to-dos", isOn: $autoAcceptVerifiedTodos)
                Text("Only to-dos whose quote is confirmed by the transcript are accepted automatically.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Show decision log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([TodoDecisionLog.shared.fileURL])
            }
            .disabled(!decisionLogExists)
            .help(decisionLogExists
                  ? "Reveal the log of accepted, edited and rejected to-dos"
                  : "No to-do decisions have been logged yet")
        }
        .onAppear {
            decisionLogExists = FileManager.default.fileExists(atPath: decisionLogURL.path)
        }
    }
}
