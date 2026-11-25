import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File menu command that writes the selected meeting as a
/// `casablanca.eval-export` v1 JSON file, for scoring with `tools/eval/casaeval.py`.
struct EvaluationExportCommands: Commands {
    let viewModel: MeetingListViewModel
    let toastCenter: ToastCenter

    var body: some Commands {
        CommandGroup(after: .importExport) {
            /// Exports the selected meeting for evaluation. The file holds the
            /// full transcript and summary: keep it out of git (save under
            /// `tools/eval/exports/`, which is git-ignored).
            Button("Export Meeting for Evaluation…") {
                guard let meeting = viewModel.selectedMeeting else { return }
                export(meeting)
            }
            .disabled(!EvaluationExport.canExport(viewModel.selectedMeeting))
        }
    }

    @MainActor
    private func export(_ meeting: Meeting) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let data: Data
        do {
            let document = EvaluationExport.document(for: meeting, exportedAt: Date(), appVersion: appVersion)
            data = try EvaluationExport.encode(document)
        } catch {
            toastCenter.show(message: error.localizedDescription)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = EvaluationExport.suggestedFileName(for: meeting)
        panel.canCreateDirectories = true
        let toastCenter = toastCenter
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                toastCenter.show(message: "Exported for evaluation")
            } catch {
                toastCenter.show(message: error.localizedDescription)
            }
        }
    }
}

extension EvaluationExport {
    /// True iff the meeting has a transcript or summary with non-whitespace text.
    static func canExport(_ meeting: Meeting?) -> Bool {
        guard let meeting else { return false }
        return hasText(meeting.transcript) || hasText(meeting.summary)
    }

    private static func hasText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
