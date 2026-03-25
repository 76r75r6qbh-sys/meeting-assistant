import Foundation

enum ObsidianExportError: LocalizedError {
    case vaultNotConfigured
    case vaultNotFound(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .vaultNotConfigured:
            return "No Obsidian vault path configured. Set it in Settings > General."
        case .vaultNotFound(let path):
            return "Obsidian vault folder not found at \(path)."
        case .writeFailed(let reason):
            return "Failed to export to Obsidian: \(reason)"
        }
    }
}

enum ObsidianExportService {

    /// Export the meeting summary to Obsidian as `YYYY-MM-DD Meeting Subject.md`
    /// inside the `meeting notes` subfolder of the vault.
    @discardableResult
    static func exportSummary(meeting: Meeting) throws -> URL {
        let dir = try meetingNotesDirectory()
        let fileURL = dir.appendingPathComponent("\(meeting.obsidianFileName).md")
        let content = buildSummaryMarkdown(meeting: meeting)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Export the raw user notes (timestamped + freeform) to Obsidian as
    /// `YYYY-MM-DD Meeting Subject - Notes.md` inside `meeting notes`.
    @discardableResult
    static func exportRawNotes(meeting: Meeting) throws -> URL {
        let dir = try meetingNotesDirectory()
        let fileURL = dir.appendingPathComponent("\(meeting.obsidianFileName) - Notes.md")
        let content = buildRawNotesMarkdown(meeting: meeting)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Export both summary and raw notes. Returns the URLs of both files.
    static func exportAll(meeting: Meeting) throws -> (summary: URL, notes: URL) {
        let summaryURL = try exportSummary(meeting: meeting)
        let notesURL = try exportRawNotes(meeting: meeting)
        return (summaryURL, notesURL)
    }

    /// Check whether the vault is configured and exists.
    static var isAvailable: Bool {
        guard let path = vaultPath, !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Private

    private static var vaultPath: String? {
        UserDefaults.standard.string(forKey: "obsidianVaultPath")
    }

    private static func meetingNotesDirectory() throws -> URL {
        guard let path = vaultPath, !path.isEmpty else {
            throw ObsidianExportError.vaultNotConfigured
        }

        let vaultURL = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ObsidianExportError.vaultNotFound(path)
        }

        let notesDir = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        } catch {
            throw ObsidianExportError.writeFailed(error.localizedDescription)
        }
        return notesDir
    }

    // MARK: - Markdown Builders

    private static func buildSummaryMarkdown(meeting: Meeting) -> String {
        var md = "---\n"
        md += "title: \"\(meeting.title)\"\n"
        md += "date: \(formattedDate(meeting.date))\n"
        if let endDate = meeting.endDate {
            md += "end: \(formattedDate(endDate))\n"
        }
        if !meeting.participants.isEmpty {
            md += "participants:\n"
            for p in meeting.participants {
                md += "  - \(p)\n"
            }
        }
        if let duration = meeting.formattedDuration {
            md += "duration: \(duration)\n"
        }
        md += "tags: [meeting]\n"
        md += "---\n\n"

        // Summary (the main content of this file)
        if let summary = meeting.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += summary
            md += "\n"
        } else {
            md += "# \(meeting.title)\n\n"
            md += "*No summary generated yet.*\n"
        }

        // Link to notes file if there are notes
        if hasAnyNotes(meeting) {
            md += "\n---\n\n"
            md += "See also: [[\(meeting.obsidianFileName) - Notes]]\n"
        }

        return md
    }

    private static func buildRawNotesMarkdown(meeting: Meeting) -> String {
        var md = "---\n"
        md += "title: \"\(meeting.title) - Notes\"\n"
        md += "date: \(formattedDate(meeting.date))\n"
        md += "tags: [meeting, notes]\n"
        md += "---\n\n"
        md += "# \(meeting.title) - Notes\n\n"

        // Timestamped notes
        if !meeting.timestampedNotes.isEmpty {
            md += "## Timestamped Notes\n\n"
            for note in meeting.timestampedNotes {
                md += "- **[\(note.formattedTimestamp)]** \(note.text)\n"
            }
            md += "\n"
        }

        // Freeform notes
        let freeform = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeform.isEmpty {
            md += "## Freeform Notes\n\n"
            md += freeform
            md += "\n"
        }

        // Transcript excerpt (first 50 lines as reference)
        if let transcript = meeting.transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n## Transcript\n\n"
            let lines = transcript.components(separatedBy: "\n")
            let excerpt = lines.prefix(50).joined(separator: "\n")
            md += excerpt
            if lines.count > 50 {
                md += "\n\n*... (\(lines.count - 50) more lines — see full transcript in Casablanca)*\n"
            }
            md += "\n"
        }

        // Link back to summary
        md += "\n---\n\n"
        md += "See also: [[\(meeting.obsidianFileName)]]\n"

        return md
    }

    private static func hasAnyNotes(_ meeting: Meeting) -> Bool {
        !meeting.timestampedNotes.isEmpty
            || !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
