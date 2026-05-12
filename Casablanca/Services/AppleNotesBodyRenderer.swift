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
        sections.append("<h1>\(escape(meeting.obsidianFileName))</h1>")
        sections.append(meetingFactsParagraphs(for: meeting))

        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty {
            sections.append("<h2>Summary</h2>")
            sections.append(markdownToHTML(summary))
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
        sections.append("<h1>\(escape(meeting.obsidianFileName)) - Notes</h1>")
        sections.append(meetingFactsParagraphs(for: meeting))

        sections.append("<h2>Freeform Notes</h2>")
        let userNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if userNotes.isEmpty {
            sections.append("<p><i>No freeform notes captured.</i></p>")
        } else {
            sections.append(markdownToHTML(userNotes))
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

    /// Convert lightweight markdown (the dialect Ollama and humans commonly produce in summary
    /// text) into the limited HTML tag subset Apple Notes preserves on save.
    ///
    /// Block constructs supported:
    /// - `# H` / `## H` / `### H` → `<h1>` / `<h1>` / `<h2>` (Notes treats `<h1>` as the visual
    ///   "Title" style; we map both `#` and `##` to `<h1>` to match user expectations).
    /// - `- ` / `* ` bullet runs → `<ul><li>…</li></ul>`.
    /// - `1. ` / `2. ` numbered runs → `<ol><li>…</li></ol>`.
    /// - Blank line → paragraph break.
    /// - Everything else → `<p>` paragraphs, with single newlines preserved as `<br>`.
    ///
    /// Inline constructs supported (applied after block parsing on each piece of text):
    /// - `**bold**` → `<b>…</b>`
    /// - `*italic*` → `<i>…</i>`
    /// - Obsidian wikilinks `[[name]]` flattened to plain text.
    /// - All other characters HTML-escaped.
    private static func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [String] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append("<p>\(paragraphBuffer.joined(separator: "<br>"))</p>")
            paragraphBuffer.removeAll()
        }

        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let headingHTML = headingHTML(for: trimmed) {
                flushParagraph()
                blocks.append(headingHTML)
                index += 1
                continue
            }

            if isUnorderedItem(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isUnorderedItem(t) else { break }
                    let content = String(t.dropFirst(2))
                    items.append("<li>\(inlineMarkdown(content))</li>")
                    index += 1
                }
                blocks.append("<ul>\(items.joined())</ul>")
                continue
            }

            if let firstItem = orderedItemContent(trimmed) {
                flushParagraph()
                var items: [String] = ["<li>\(inlineMarkdown(firstItem))</li>"]
                index += 1
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let content = orderedItemContent(t) else { break }
                    items.append("<li>\(inlineMarkdown(content))</li>")
                    index += 1
                }
                blocks.append("<ol>\(items.joined())</ol>")
                continue
            }

            paragraphBuffer.append(inlineMarkdown(rawLine))
            index += 1
        }

        flushParagraph()
        return blocks.joined()
    }

    private static func headingHTML(for trimmed: String) -> String? {
        if trimmed.hasPrefix("### ") {
            return "<h2>\(inlineMarkdown(String(trimmed.dropFirst(4))))</h2>"
        }
        if trimmed.hasPrefix("## ") {
            return "<h1>\(inlineMarkdown(String(trimmed.dropFirst(3))))</h1>"
        }
        if trimmed.hasPrefix("# ") {
            return "<h1>\(inlineMarkdown(String(trimmed.dropFirst(2))))</h1>"
        }
        return nil
    }

    private static func isUnorderedItem(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
    }

    /// Returns the content after the `N. ` prefix when the trimmed line starts with one or more
    /// digits followed by a period and a space; otherwise nil.
    private static func orderedItemContent(_ trimmed: String) -> String? {
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[trimmed.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = trimmed.index(after: dotIndex)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return String(trimmed[trimmed.index(after: afterDot)...])
    }

    /// Apply inline conversions and escape the result so it's safe to drop into HTML.
    /// Wikilinks are stripped first (their brackets are not HTML-significant). Bold/italic are
    /// converted into `<b>`/`<i>` tags AFTER escaping the rest of the text, so the user's
    /// `<` / `>` / `&` end up as entities.
    private static func inlineMarkdown(_ text: String) -> String {
        let withoutWikilinks = stripWikilinks(text)
        var escaped = escape(withoutWikilinks)
        escaped = applyPaired(escaped, delimiter: "**", tag: "b")
        escaped = applyPaired(escaped, delimiter: "*", tag: "i")
        return escaped
    }

    /// Replace pairs of `delimiter` in `text` with `<tag>…</tag>`. Unmatched delimiters are left
    /// in place verbatim. Non-greedy and left-to-right; nested same-delimiter pairs collapse to
    /// the outer pair.
    private static func applyPaired(_ text: String, delimiter: String, tag: String) -> String {
        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let openRange = text.range(of: delimiter, range: cursor..<text.endIndex) else {
                output.append(contentsOf: text[cursor..<text.endIndex])
                break
            }
            output.append(contentsOf: text[cursor..<openRange.lowerBound])
            guard let closeRange = text.range(of: delimiter, range: openRange.upperBound..<text.endIndex) else {
                output.append(contentsOf: text[openRange.lowerBound..<text.endIndex])
                break
            }
            let inner = text[openRange.upperBound..<closeRange.lowerBound]
            output.append("<\(tag)>\(inner)</\(tag)>")
            cursor = closeRange.upperBound
        }
        return output
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
