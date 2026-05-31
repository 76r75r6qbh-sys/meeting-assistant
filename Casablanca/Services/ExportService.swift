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
    enum DestinationResult {
        case obsidian(ExportResult)
        case appleNotes(summaryNoteId: String?, rawNotesNoteId: String)

        var destinationDisplayName: String {
            switch self {
            case .obsidian: return "Obsidian"
            case .appleNotes: return "Apple Notes"
            }
        }
    }

    @MainActor
    static func exportCompletedMeeting(
        _ meeting: Meeting,
        defaults: UserDefaults = .standard,
        appleNotesScripting: AppleNotesScripting? = nil
    ) async throws -> DestinationResult {
        switch AppPreferences.exportDestination(in: defaults) {
        case .obsidian:
            return .obsidian(try ObsidianMeetingExporter.exportCompletedMeeting(meeting))
        case .appleNotes:
            let scripting = appleNotesScripting ?? NSAppleScriptAppleNotesScripting()
            let exporter = AppleNotesMeetingExporter(scripting: scripting)
            let result = try await exporter.export(meeting)
            return .appleNotes(summaryNoteId: result.summaryNoteId, rawNotesNoteId: result.rawNotesNoteId)
        }
    }

    @MainActor
    static func exportRawNotes(
        _ meeting: Meeting,
        defaults: UserDefaults = .standard,
        appleNotesScripting: AppleNotesScripting? = nil
    ) async throws -> DestinationResult {
        switch AppPreferences.exportDestination(in: defaults) {
        case .obsidian:
            return .obsidian(try ObsidianMeetingExporter.exportRawNotes(meeting))
        case .appleNotes:
            let scripting = appleNotesScripting ?? NSAppleScriptAppleNotesScripting()
            let exporter = AppleNotesMeetingExporter(scripting: scripting)
            let result = try await exporter.exportRawNotesOnly(meeting)
            return .appleNotes(summaryNoteId: nil, rawNotesNoteId: result.rawNotesNoteId)
        }
    }

    @MainActor
    static func exportAutomaticallyIfEnabled(
        _ meeting: Meeting,
        defaults: UserDefaults = .standard,
        appleNotesScripting: AppleNotesScripting? = nil
    ) async {
        guard isAutoExportOn(defaults: defaults),
              hasExportableContent(meeting)
        else { return }
        do {
            _ = try await exportCompletedMeeting(meeting, defaults: defaults, appleNotesScripting: appleNotesScripting)
        } catch {
            print("Automatic export skipped:", error.localizedDescription)
        }
    }

    static func hasExportableContent(_ meeting: Meeting) -> Bool {
        meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isAutoExportOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.autoExportEnabled)
    }
}
