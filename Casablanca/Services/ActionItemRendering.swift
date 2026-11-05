// Casablanca/Services/ActionItemRendering.swift
import Foundation

/// Renders a summary's `## Decisions` and `## Action Items` sections from its
/// structured facts, so the stored markdown always matches the stored items.
///
/// Bullet format (shared with Track C's eval export, ruling R5):
/// `**owner** — task (yyyy-MM-dd) [mm:ss]`, each suffix only when set.
/// `SummaryResponseParser` and `ActionItemOwnership` read the result as before;
/// `strippingSuffix` takes the suffix off an action again.
enum ActionItemRendering {
    /// Prefix of a decision whose quote the verifier did not find.
    static let unverifiedDecisionPrefix = "⚠︎ "

    // MARK: - Bullets

    /// `**Kim** — Stuur offerte (2026-11-06) [12:34]`; a missing owner is `**?**`.
    static func bullet(for item: ExtractedActionItem) -> String {
        let owner = item.owner.map(singleLine)?.replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        var line = "**\(owner.flatMap { $0.isEmpty ? nil : $0 } ?? "?")** — \(singleLine(item.task))"
        if let due = item.due, !due.isEmpty { line += " (\(due))" }
        if let timestamp = item.timestamp, !timestamp.isEmpty { line += " [\(timestamp)]" }
        return line
    }

    /// `<text> [12:34]`; an `.unsupported` decision gets `unverifiedDecisionPrefix`.
    static func decisionBullet(for decision: ExtractedDecision) -> String {
        var line = singleLine(decision.text)
        if let timestamp = decision.timestamp, !timestamp.isEmpty { line += " [\(timestamp)]" }
        return decision.verified == .unsupported ? unverifiedDecisionPrefix + line : line
    }

    /// `action` without a trailing ` [mm:ss]` / ` [h:mm:ss]` (only a label
    /// `TranscriptLineFormat` can read) and then a trailing ` (yyyy-MM-dd)`.
    /// Anything else, such as `Bel [Kim]`, is left alone.
    static func strippingSuffix(_ action: String) -> String {
        var text = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #" \[[0-9:]+\]$"#, options: .regularExpression) {
            let label = String(text[range].dropFirst(2).dropLast())
            if TranscriptLineFormat.seconds(fromLabel: label) != nil {
                text.removeSubrange(range)
            }
        }
        if let range = text.range(of: #" \(\d{4}-\d{2}-\d{2}\)$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }

    // MARK: - Sections

    /// Both sections of `markdown` rendered from `facts`. When the facts carry
    /// no decisions but the markdown lists some, the markdown's decisions stay:
    /// the decisions have no "never fewer" guard upstream, unlike action items.
    static func render(_ facts: SummaryFacts, into markdown: String) -> String {
        var result = markdown
        let markdownDecisions = SummaryResponseParser.parse(markdown).decisions
        if !(facts.decisions.isEmpty && !markdownDecisions.isEmpty) {
            result = replacingSection(.decisions, in: result, bullets: facts.decisions.map(decisionBullet))
        }
        return replacingSection(.actionItems, in: result, bullets: facts.actionItems.map(bullet))
    }

    /// Replaces the body of `field`'s section (up to the next `## ` / `# `
    /// heading) with `bullets` as `- ` lines and one blank line. The section is
    /// the one `SummaryResponseParser` reads (aliases in its order, first
    /// occurrence). Without one, a heading is inserted: Dutch when the notes
    /// are Dutch; Decisions before Action Items (else before the risks heading,
    /// else at the end); Action Items directly after Decisions (else before the
    /// risks heading, else at the end).
    static func replacingSection(_ field: SummaryResponseParser.Field, in markdown: String, bullets: [String]) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let body = bullets.map { "- " + singleLine($0) }

        if let heading = headingIndex(field, in: lines) {
            let end = nextHeading(after: heading, in: lines)
            var replacement = body
            if end < lines.count || markdown.hasSuffix("\n") { replacement.append("") }
            lines.replaceSubrange((heading + 1)..<end, with: replacement)
            return lines.joined(separator: "\n")
        }

        let title = isDutch(lines) ? dutchTitle(field) : englishTitle(field)
        let section = ["## " + title] + body
        let insertAt: Int?
        switch field {
        case .decisions:
            insertAt = headingIndex(.actionItems, in: lines) ?? risksHeadingIndex(in: lines)
        case .actionItems:
            if let decisions = headingIndex(.decisions, in: lines) {
                let end = nextHeading(after: decisions, in: lines)
                insertAt = end < lines.count ? end : nil
            } else {
                insertAt = risksHeadingIndex(in: lines)
            }
        }

        if let index = insertAt {
            var inserted = section + [""]
            if index > 0, !lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                inserted.insert("", at: 0)
            }
            lines.insert(contentsOf: inserted, at: index)
            return lines.joined(separator: "\n")
        }

        // At the end, one blank line after the existing content.
        let hadTrailingNewline = markdown.hasSuffix("\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines += section
        if hadTrailingNewline { lines.append("") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isHeading(_ line: String) -> Bool {
        line.hasPrefix("## ") || line.hasPrefix("# ")
    }

    private static func title(of line: String) -> String? {
        line.hasPrefix("## ") ? SummaryResponseParser.normalizeTitle(String(line.dropFirst(3))) : nil
    }

    /// First `## ` heading of the alias the parser would pick for `field`.
    private static func headingIndex(_ field: SummaryResponseParser.Field, in lines: [String]) -> Int? {
        headingIndex(aliases: SummaryResponseParser.headingAliases(for: field), in: lines)
    }

    private static func headingIndex(aliases: [String], in lines: [String]) -> Int? {
        for alias in aliases {
            let key = SummaryResponseParser.normalizeTitle(alias)
            if let index = lines.firstIndex(where: { title(of: $0) == key }) { return index }
        }
        return nil
    }

    private static func risksHeadingIndex(in lines: [String]) -> Int? {
        let keys = Set((SummaryResponseParser.sectionAliases["risks"] ?? []).map(SummaryResponseParser.normalizeTitle))
        return lines.firstIndex { title(of: $0).map(keys.contains) ?? false }
    }

    private static func nextHeading(after index: Int, in lines: [String]) -> Int {
        lines[(index + 1)...].firstIndex(where: isHeading) ?? lines.count
    }

    /// Dutch closing-section titles the parser accepts.
    private static let dutchTitles: Set<String> = Set([
        "Besluiten", "Actiepunten", "Actielijst", "Risico\u{2019}s en blockers", "Risico\u{2019}s",
        "Opvolging", "Vervolgacties",
    ].map(SummaryResponseParser.normalizeTitle))

    private static func isDutch(_ lines: [String]) -> Bool {
        lines.contains { line in
            if line.hasPrefix("# "), SummaryResponseParser.normalizeTitle(String(line.dropFirst(2))) == "samenvatting" {
                return true
            }
            return title(of: line).map(dutchTitles.contains) ?? false
        }
    }

    private static func dutchTitle(_ field: SummaryResponseParser.Field) -> String {
        switch field {
        case .decisions: return "Besluiten"
        case .actionItems: return "Actiepunten"
        }
    }

    private static func englishTitle(_ field: SummaryResponseParser.Field) -> String {
        switch field {
        case .decisions: return "Decisions"
        case .actionItems: return "Action Items"
        }
    }
}
