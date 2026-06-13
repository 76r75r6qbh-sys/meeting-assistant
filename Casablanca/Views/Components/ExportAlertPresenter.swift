import AppKit

/// Shared modal alert used after an export completes or fails. Optionally offers
/// a "Show in Finder" button when files were written to disk.
///
/// Extracted verbatim from the previously-duplicated `presentExportAlert`
/// methods in `RecordedMeetingView` and `NotesEditorView`.
func presentExportAlert(title: String, message: String, exportedURLs: [URL]) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message

    if exportedURLs.isEmpty {
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return
    }

    alert.addButton(withTitle: "Show in Finder")
    alert.addButton(withTitle: "OK")

    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting(exportedURLs)
    }
}
