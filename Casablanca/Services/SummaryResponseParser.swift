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

    // MARK: - Section alias map

    /// Canonical field → set of accepted header titles (case-insensitive, whitespace-trimmed,
    /// trailing `:` stripped, typographic apostrophe U+2019 treated equal to ASCII `'`).
    private static let sectionAliases: [String: [String]] = [
        "decisions": ["Decisions", "Besluiten"],
        "todoTexts": ["Action Items", "Actiepunten", "Actielijst"],
        "risks":     ["Risks and Blockers", "Risks", "Risico\u{2019}s en blockers", "Risico\u{2019}s"],
        "followUps": ["Follow-ups", "Followups", "Follow ups", "Opvolging", "Vervolgacties"],
    ]

    /// Normalizes a section title for alias comparison:
    /// lowercased, whitespace-trimmed, trailing `:` stripped,
    /// typographic apostrophe (U+2019) replaced with ASCII `'`.
    private static func normalizeTitle(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(":") { s = String(s.dropLast()) }
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        return s.lowercased()
    }

    static func parse(_ response: String) -> ParsedResponse {
        let sections = splitSections(response)   // [title: body]; "__intro__" = text before first "## "

        // Build a lookup: normalized title → body, for alias resolution.
        let normalizedSections: [String: String] = Dictionary(
            sections.map { (normalizeTitle($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }  // first occurrence wins (matches splitSections semantics)
        )

        func bullets(forField field: String) -> [String] {
            let aliases = sectionAliases[field] ?? []
            // Find the first alias that matches a section in the document.
            for alias in aliases {
                let key = normalizeTitle(alias)
                guard let body = normalizedSections[key] else { continue }
                return body.components(separatedBy: "\n").compactMap { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("- ") else { return nil }
                    let text = String(t.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
            }
            return []
        }

        return ParsedResponse(
            summary: sections["__intro__"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                     ?? response.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: bullets(forField: "decisions"),
            todoTexts: bullets(forField: "todoTexts"),
            risks:     bullets(forField: "risks"),
            followUps: bullets(forField: "followUps"),
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
