// Casablanca/Services/SummaryResponseParser.swift
import Foundation

enum SummaryResponseParser {
    struct ParsedResponse {
        let summary: String          // intro prose before the first "## " (unchanged semantics)
        let decisions: [String]
        let todoTexts: [String]      // Action Items (name kept for callers)
        let risks: [String]
        let followUps: [String]
        let rawMarkdown: String      // full original response, for persistence + re-parse on display
    }

    static func parse(_ response: String) -> ParsedResponse {
        let sections = splitSections(response)   // [title: body]; "__intro__" = text before first "## "

        func bullets(_ title: String) -> [String] {
            guard let body = sections[title] else { return [] }
            return body.components(separatedBy: "\n").compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- ") else { return nil }
                let text = String(t.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }

        return ParsedResponse(
            summary: sections["__intro__"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                     ?? response.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: bullets("Decisions"),
            todoTexts: bullets("Action Items"),
            risks: bullets("Risks and Blockers"),
            followUps: bullets("Follow-ups"),
            rawMarkdown: response
        )
    }

    /// Splits a markdown response into sections delimited by "## " (two-hash) headers.
    /// - "__intro__" maps to everything before the first "## " line (the single-hash
    ///   "# Summary" header, if present, is part of the intro).
    /// - Each "## <Title>" maps to its body: the text from after the header line up to
    ///   the next "## " line or end of string. The title is the text after "## " up to
    ///   end-of-line (e.g. "## Risks and Blockers" -> key "Risks and Blockers").
    private static func splitSections(_ response: String) -> [String: String] {
        var sections: [String: String] = [:]

        // Split on newlines, preserving the ability to detect "## " at line starts.
        let lines = response.components(separatedBy: "\n")

        var currentKey = "__intro__"
        var currentBody: [String] = []

        func flush() {
            // Keep the last-written value if a header repeats; first occurrence wins via guard.
            if sections[currentKey] == nil {
                sections[currentKey] = currentBody.joined(separator: "\n")
            }
        }

        for line in lines {
            if line.hasPrefix("## ") {
                // Close out the previous section.
                flush()
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentKey = title
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }
        flush()

        return sections
    }
}
