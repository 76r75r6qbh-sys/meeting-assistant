import Foundation

enum AppleNotesBodyRenderer {
    enum MarkerKind: String {
        case summary
        case notes
    }

    /// Single source of truth for the identity marker embedded in note bodies and scanned during
    /// upsert. Format: `Casablanca id: <UUID> / <summary|notes>`. The renderer wraps it in `<p>`
    /// for the body; the exporter passes the bare string to `findNote(markerContaining:in:)`.
    static func marker(for meetingID: UUID, kind: MarkerKind) -> String {
        "Casablanca id: \(meetingID.uuidString) / \(kind.rawValue)"
    }

    static func summaryHTML(for meeting: Meeting) -> String {
        var sections: [String] = []
        sections.append("<h1>\(escape(meeting.title))</h1>")
        sections.append(meetingFactsParagraphs(for: meeting))

        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty {
            sections.append("<h2>Summary</h2>")
            sections.append(paragraphs(from: summary))
        }

        if !meeting.todos.isEmpty {
            sections.append("<h2>Action Items</h2>")
            sections.append(todoList(meeting.todos))
        }

        sections.append(markerParagraph(meetingId: meeting.id, kind: .summary))
        return wrap(sections.joined())
    }

    static func rawNotesHTML(for meeting: Meeting) -> String {
        var sections: [String] = []
        sections.append("<h1>\(escape(meeting.title)) - Raw Notes</h1>")
        sections.append(meetingFactsParagraphs(for: meeting))

        sections.append("<h2>Freeform Notes</h2>")
        let userNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if userNotes.isEmpty {
            sections.append("<p><i>No freeform notes captured.</i></p>")
        } else {
            sections.append(paragraphs(from: userNotes))
        }

        if !meeting.timestampedNotes.isEmpty {
            sections.append("<h2>Timestamped Notes</h2>")
            let items = meeting.timestampedNotes.map { note in
                "<li>[\(escape(note.formattedTimestamp))] \(escape(stripWikilinks(note.text)))</li>"
            }.joined()
            sections.append("<ul>\(items)</ul>")
        }

        sections.append(markerParagraph(meetingId: meeting.id, kind: .notes))
        return wrap(sections.joined())
    }

    // MARK: - Helpers

    private static func wrap(_ body: String) -> String {
        "<html><body>\(body)</body></html>"
    }

    private static func markerParagraph(meetingId: UUID, kind: MarkerKind) -> String {
        // Visible footer marker — Notes is known to strip HTML comments on save, so the marker
        // is rendered as plain text inside a trailing <p>.
        "<p>\(marker(for: meetingId, kind: kind))</p>"
    }

    private static func meetingFactsParagraphs(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let scheduled = formatter.string(from: meeting.date)
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let participantsText = participants.isEmpty ? "Not captured." : participants.joined(separator: ", ")
        let recordingText = meeting.recordingDuration.map(formatDuration) ?? "Not recorded."

        return """
        <ul>\
        <li>Scheduled: \(escape(scheduled))</li>\
        <li>Participants: \(escape(participantsText))</li>\
        <li>Recording: \(escape(recordingText))</li>\
        </ul>
        """
    }

    private static func todoList(_ todos: [TodoItem]) -> String {
        let items = todos.map { todo in
            let glyph = todo.isCompleted ? "☑" : "☐"
            return "<li>\(glyph) \(escape(stripWikilinks(todo.text)))</li>"
        }.joined()
        return "<ul>\(items)</ul>"
    }

    private static func paragraphs(from text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { chunk -> String in
                let escaped = escape(stripWikilinks(chunk))
                let withBreaks = escaped.replacingOccurrences(of: "\n", with: "<br>")
                return "<p>\(withBreaks)</p>"
            }
            .joined()
    }

    private static func stripWikilinks(_ text: String) -> String {
        var result = text
        while let openRange = result.range(of: "[["),
              let closeRange = result.range(of: "]]", range: openRange.upperBound..<result.endIndex) {
            let inner = String(result[openRange.upperBound..<closeRange.lowerBound])
            result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: inner)
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }
}
