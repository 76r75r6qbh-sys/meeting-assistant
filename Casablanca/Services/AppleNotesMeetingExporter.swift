import Foundation

struct AppleNotesExportResult {
    let summaryNoteId: String?
    let rawNotesNoteId: String
}

final class AppleNotesMeetingExporter {
    static let folderName = "Casablanca"

    private let scripting: AppleNotesScripting

    init(scripting: AppleNotesScripting) {
        self.scripting = scripting
    }

    @discardableResult
    func export(_ meeting: Meeting) async throws -> AppleNotesExportResult {
        let folder = try await ensureFolderMappingErrors()

        let summaryHTML = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        let rawNotesHTML = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        let shouldExportSummary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let summaryMarker = "Casablanca id: \(meeting.id.uuidString) / summary"
        let notesMarker = "Casablanca id: \(meeting.id.uuidString) / notes"

        var summaryId: String? = nil
        if shouldExportSummary {
            summaryId = try await upsert(
                cachedId: meeting.appleNotesSummaryNoteID,
                marker: summaryMarker,
                title: meeting.obsidianFileName,
                body: summaryHTML,
                folder: folder
            )
            meeting.appleNotesSummaryNoteID = summaryId
        } else {
            meeting.appleNotesSummaryNoteID = nil
        }

        let rawNotesId = try await upsert(
            cachedId: meeting.appleNotesRawNotesNoteID,
            marker: notesMarker,
            title: "\(meeting.obsidianFileName) - Notes",
            body: rawNotesHTML,
            folder: folder
        )
        meeting.appleNotesRawNotesNoteID = rawNotesId

        return AppleNotesExportResult(summaryNoteId: summaryId, rawNotesNoteId: rawNotesId)
    }

    @discardableResult
    func exportRawNotesOnly(_ meeting: Meeting) async throws -> AppleNotesExportResult {
        let folder = try await ensureFolderMappingErrors()
        let rawNotesHTML = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        let notesMarker = "Casablanca id: \(meeting.id.uuidString) / notes"

        let rawNotesId = try await upsert(
            cachedId: meeting.appleNotesRawNotesNoteID,
            marker: notesMarker,
            title: "\(meeting.obsidianFileName) - Notes",
            body: rawNotesHTML,
            folder: folder
        )
        meeting.appleNotesRawNotesNoteID = rawNotesId

        return AppleNotesExportResult(summaryNoteId: nil, rawNotesNoteId: rawNotesId)
    }

    private func ensureFolderMappingErrors() async throws -> AppleNotesFolderRef {
        do {
            return try await scripting.ensureFolder(named: Self.folderName)
        } catch {
            throw mapped(error)
        }
    }

    private func upsert(
        cachedId: String?,
        marker: String,
        title: String,
        body: String,
        folder: AppleNotesFolderRef
    ) async throws -> String {
        do {
            // 1. Cached id fast path with body verification.
            if let cachedId,
               let existingBody = try await scripting.noteBody(id: cachedId),
               existingBody.contains(marker) {
                try await scripting.updateNote(id: cachedId, title: title, body: body)
                return cachedId
            }

            // 2. Marker scan.
            if let match = try await scripting.findNote(markerContaining: marker, in: folder) {
                try await scripting.updateNote(id: match.id, title: title, body: body)
                return match.id
            }

            // 3. Create.
            let ref = try await scripting.createNote(title: title, body: body, in: folder)
            return ref.id
        } catch let error as AppleNotesExportError {
            throw error
        } catch {
            throw mapped(error)
        }
    }

    private func mapped(_ error: Error) -> Error {
        let nsError = error as NSError
        if let code = nsError.userInfo["NSAppleScriptErrorNumber"] as? Int {
            return AppleNotesExportError.from(appleScriptErrorCode: code, message: nsError.localizedDescription)
        }
        if nsError.domain == "NSAppleScriptErrorDomain", let code = nsError.userInfo["NSAppleScriptErrorNumber"] as? Int {
            return AppleNotesExportError.from(appleScriptErrorCode: code, message: nsError.localizedDescription)
        }
        return error
    }
}
