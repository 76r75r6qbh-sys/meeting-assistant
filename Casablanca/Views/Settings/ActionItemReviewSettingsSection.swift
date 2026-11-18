import AppKit
import SwiftUI

/// Settings → AI → To-do Review: auto-accept for verified to-dos and the
/// decision log (`TodoDecisionLog`).
struct ActionItemReviewSettingsSection: View {
    @AppStorage(AppPreferenceKey.autoAcceptVerifiedTodos) private var autoAcceptVerifiedTodos = false
    /// Checked when the section appears; the log is created on the first decision.
    @State private var decisionLogExists = false
    @State private var confirmingDeleteLog = false

    private let decisionLogURL = TodoDecisionLog.shared.fileURL

    var body: some View {
        Section("To-do Review") {
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Toggle("Auto-accept verified to-dos", isOn: $autoAcceptVerifiedTodos)
                Text("Only to-dos whose quote is confirmed by the transcript are accepted automatically. The decision log stays on this Mac and holds each reviewed to-do's text and quote.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Show decision log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([TodoDecisionLog.shared.fileURL])
                }
                .help(decisionLogExists
                      ? "Reveal the log of accepted, edited and rejected to-dos"
                      : "No to-do decisions have been logged yet")

                Button("Delete decision log", role: .destructive) {
                    confirmingDeleteLog = true
                }
                .help(decisionLogExists
                      ? "Delete the log of accepted, edited and rejected to-dos"
                      : "No to-do decisions have been logged yet")
            }
            .disabled(!decisionLogExists)
            .confirmationDialog(
                "Delete the to-do decision log?",
                isPresented: $confirmingDeleteLog
            ) {
                Button("Delete decision log", role: .destructive) {
                    TodoDecisionLog.shared.deleteLog()
                    decisionLogExists = FileManager.default.fileExists(atPath: decisionLogURL.path)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every logged review decision, with its to-do text and quote, is removed from this Mac. Your to-dos themselves are not changed.")
            }
        }
        .onAppear {
            decisionLogExists = FileManager.default.fileExists(atPath: decisionLogURL.path)
        }
    }
}
