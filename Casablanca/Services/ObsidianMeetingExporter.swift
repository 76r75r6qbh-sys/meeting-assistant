import Foundation

enum ObsidianMeetingExporter {
    static func exportCompletedMeeting(_ meeting: Meeting) throws -> ExportResult {
        let directory = try meetingNotesDirectory()
        let notesURL = rawNotesURL(for: meeting, in: directory)
        let summaryURL = summaryURL(for: meeting, in: directory)
        let shouldExportSummary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        try rawNotesMarkdown(for: meeting, summaryFileName: shouldExportSummary ? summaryURL.deletingPathExtension().lastPathComponent : nil)
            .write(to: notesURL, atomically: true, encoding: .utf8)

        if shouldExportSummary {
            try summaryMarkdown(for: meeting, notesFileName: notesURL.deletingPathExtension().lastPathComponent)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        }

        return ExportResult(summaryURL: shouldExportSummary ? summaryURL : nil, notesURL: notesURL)
    }

    static func exportRawNotes(_ meeting: Meeting) throws -> ExportResult {
        let directory = try meetingNotesDirectory()
        let notesURL = rawNotesURL(for: meeting, in: directory)

        try rawNotesMarkdown(for: meeting, summaryFileName: nil)
            .write(to: notesURL, atomically: true, encoding: .utf8)

        return ExportResult(summaryURL: nil, notesURL: notesURL)
    }

    // MARK: - Private (moved verbatim from ExportService)

    private static func meetingNotesDirectory() throws -> URL {
        let vaultPath = UserDefaults.standard.string(forKey: AppPreferenceKey.obsidianVaultPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !vaultPath.isEmpty else {
            throw ExportError.missingVaultPath
        }

        let directory = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent("meeting notes", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func rawNotesURL(for meeting: Meeting, in directory: URL) -> URL {
        directory.appendingPathComponent("\(meeting.obsidianFileName) - Notes.md")
    }

    private static func summaryURL(for meeting: Meeting, in directory: URL) -> URL {
        directory.appendingPathComponent("\(meeting.obsidianFileName).md")
    }

    private static func summaryMarkdown(for meeting: Meeting, notesFileName: String) -> String {
        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notesLink = "[[\(notesFileName)]]"
        let actionItemsSection = meeting.todos.isEmpty
            ? ""
            : "\n\n## Action Items\n\n" + meeting.todos.map { "- [\($0.isCompleted ? "x" : " ")] \($0.text)" }.joined(separator: "\n")

        return """
        ---
        title: \(yamlEscaped(meeting.obsidianFileName))
        meeting_title: \(yamlEscaped(meeting.title))
        meeting_date: \(yamlEscaped(isoTimestamp(meeting.date)))
        casablanca_type: "meeting-summary"\(tagsFrontmatterLine(for: meeting))
        raw_notes: \(yamlEscaped(notesLink))
        ---

        # Summary

        \(summary)\(actionItemsSection)

        ## Meeting

        - Scheduled: \(meetingDisplayDate(meeting))
        \(participantsLine(for: meeting))
        \(recordingLine(for: meeting))
        - Transcript: Saved locally by Casablanca.

        ## Raw Notes

        \(notesLink)
        """
    }

    private static func rawNotesMarkdown(for meeting: Meeting, summaryFileName: String?) -> String {
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedFreeformNotes = freeformNotes.isEmpty ? "_No freeform notes captured._" : freeformNotes
        let summaryLink = summaryFileName.map { "[[\($0)]]" } ?? "_Not exported yet._"

        return """
        ---
        title: \(yamlEscaped("\(meeting.obsidianFileName) - Notes"))
        meeting_title: \(yamlEscaped(meeting.title))
        meeting_date: \(yamlEscaped(isoTimestamp(meeting.date)))
        casablanca_type: "raw-notes"\(tagsFrontmatterLine(for: meeting))
        summary_note: \(yamlEscaped(summaryLink))
        ---

        # Raw Notes

        ## Meeting

        - Scheduled: \(meetingDisplayDate(meeting))
        \(participantsLine(for: meeting))
        \(recordingLine(for: meeting))
        - Summary note: \(summaryLink)

        ## Freeform Notes

        \(renderedFreeformNotes)
        """
    }

    private static func participantsLine(for meeting: Meeting) -> String {
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !participants.isEmpty else { return "- Participants: Not captured." }
        return "- Participants: \(participants.joined(separator: ", "))"
    }

    private static func recordingLine(for meeting: Meeting) -> String {
        guard let duration = meeting.recordingDuration else { return "- Recording: Not recorded." }
        return "- Recording: \(formattedDuration(duration))"
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    private static func meetingDisplayDate(_ meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: meeting.date)
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A leading-newline `tags:` YAML block-sequence line for the frontmatter, or
    /// empty string when the meeting has no tags (so the key is omitted entirely).
    /// Tags are normalized (lowercase, trimmed) at write time, but we still quote
    /// each value so any spaces stay valid YAML and Obsidian's tag parser is happy.
    /// Emitted as a `casablanca-` prefix-free flow list under `tags:` so Obsidian's
    /// native tag system picks them up.
    static func tagsFrontmatterLine(for meeting: Meeting) -> String {
        let tags = Meeting.normalizeTags(meeting.tags)
        guard !tags.isEmpty else { return "" }
        let items = tags.map { "\n  - \(yamlEscaped($0))" }.joined()
        return "\ntags:\(items)"
    }

    private static func yamlEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
