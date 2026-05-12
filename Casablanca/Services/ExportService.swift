import Foundation

enum ExportError: LocalizedError {
    case missingVaultPath

    var errorDescription: String? {
        switch self {
        case .missingVaultPath:
            return "Set your Obsidian vault path in Settings before exporting."
        }
    }
}

struct ExportResult {
    let summaryURL: URL?
    let notesURL: URL

    var exportedURLs: [URL] {
        [summaryURL, notesURL].compactMap { $0 }
    }
}

enum ExportService {
    static func exportAutomaticallyIfEnabled(_ meeting: Meeting) {
        guard isAutoExportOn(),
              hasExportableContent(meeting)
        else { return }

        do {
            _ = try exportCompletedMeeting(meeting)
        } catch {
            print("Automatic export skipped:", error.localizedDescription)
        }
    }

    static func exportCompletedMeeting(_ meeting: Meeting) throws -> ExportResult {
        try ObsidianMeetingExporter.exportCompletedMeeting(meeting)
    }

    static func exportRawNotes(_ meeting: Meeting) throws -> ExportResult {
        try ObsidianMeetingExporter.exportRawNotes(meeting)
    }

    static func hasExportableContent(_ meeting: Meeting) -> Bool {
        meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !meeting.timestampedNotes.isEmpty
    }

    // Read the unified auto-export switch. Until Task 15 migrates SettingsView to write the new
    // key, the SettingsView UI keeps writing `legacyAutoExportNotesToObsidian` — so we OR-read
    // both keys here to keep the toggle responsive during the migration window. Task 15 removes
    // the legacy OR fallback.
    static func isAutoExportOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.autoExportEnabled)
            || defaults.bool(forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian)
    }
}
