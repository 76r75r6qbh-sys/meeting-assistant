import Foundation

/// Parsed `ticket_draft` body (draftType `jira`).
///
/// ```
/// Project: <IO|MCINT|MCPART|...>
/// Issue type: <Bug|Story|Task|...>
/// Summary: <short Jira summary>
/// Priority: <High|Medium|Low>
/// Labels: <comma-separated, optional>
/// Components: <comma-separated, optional>
/// Fix version: <optional>
/// Epic link: <issue key, optional>
/// Assignee: <username or "Unassigned">
/// Custom fields:
///   - Release notes radio: <Yes-External|Yes-Internal|No|Unknown>
///   - <other custom field>: <value>
///
/// ---DESCRIPTION---
/// <the issue description body in Jira markdown>
/// ```
///
/// The regular `init?(parsing:)` requires Project, Issue type, and Summary. The
/// lenient `init?(parsingSlim:)` only requires Project and Summary (used by
/// RoadmapCommitmentBody's nested `---TICKET---` block, which omits issue type,
/// priority, etc.). Description is everything after `---DESCRIPTION---`, verbatim;
/// when the delimiter is absent the description is "".
///
/// `customFields` is an ORDERED list of (name, value) pairs parsed from the
/// indented `- Key: value` lines under "Custom fields:" (order preserved).
struct TicketDraftBody: Equatable {
    /// An ordered custom-field entry. Equatable so round-trips compare cleanly.
    struct CustomField: Equatable {
        var name: String
        var value: String
    }

    var project: String
    var issueType: String
    var summary: String
    var priority: String
    var labels: [String]
    var components: [String]
    var fixVersion: String?
    var epicLink: String?
    var assignee: String?
    var customFields: [CustomField]
    var description: String

    init(
        project: String,
        issueType: String = "",
        summary: String,
        priority: String = "",
        labels: [String] = [],
        components: [String] = [],
        fixVersion: String? = nil,
        epicLink: String? = nil,
        assignee: String? = nil,
        customFields: [CustomField] = [],
        description: String = ""
    ) {
        self.project = project
        self.issueType = issueType
        self.summary = summary
        self.priority = priority
        self.labels = labels
        self.components = components
        self.fixVersion = fixVersion
        self.epicLink = epicLink
        self.assignee = assignee
        self.customFields = customFields
        self.description = description
    }

    init?(parsing body: String) {
        self.init(parsing: body, requireIssueType: true)
    }

    /// Lenient parse for the nested ticket inside a `roadmap_commitment` body:
    /// only Project and Summary are required (issue type, priority, etc. may be
    /// absent). Description still follows `---DESCRIPTION---` if present, but a
    /// `Description:` header line is also accepted as the description.
    init?(parsingSlim body: String) {
        self.init(parsing: body, requireIssueType: false)
    }

    private init?(parsing raw: String, requireIssueType: Bool) {
        let body = ActionBodyParsing.normalizeNewlines(raw)
        let (headers, after) = ActionBodyParsing.parseHeaders(body, bodyDelimiter: "---DESCRIPTION---")
        guard let project = headers.nonEmpty("project"),
              let summary = headers.nonEmpty("summary") else {
            return nil
        }
        if requireIssueType, headers.nonEmpty("issue type") == nil {
            return nil
        }

        self.project = project
        self.issueType = headers["issue type"] ?? ""
        self.summary = summary
        self.priority = headers["priority"] ?? ""
        self.labels = ActionBodyParsing.list(headers["labels"])
        self.components = ActionBodyParsing.list(headers["components"])
        self.fixVersion = headers.nonEmpty("fix version")
        self.epicLink = headers.nonEmpty("epic link")
        self.assignee = headers.nonEmpty("assignee")
        self.customFields = Self.parseCustomFields(body)

        if let after {
            self.description = after
        } else {
            // Slim blocks may carry the description on a single `Description:` line.
            self.description = headers["description"] ?? ""
        }
    }

    /// Parse the indented `- Key: value` lines that follow a `Custom fields:`
    /// header, preserving order. Stops at the description delimiter or at the
    /// first non-indented, non-bullet line after the block began.
    private static func parseCustomFields(_ body: String) -> [CustomField] {
        let lines = body.components(separatedBy: "\n")
        var fields: [CustomField] = []
        var inBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---DESCRIPTION---" { break }
            if !inBlock {
                if trimmed.lowercased() == "custom fields:" {
                    inBlock = true
                }
                continue
            }
            // In the custom-fields block. Bullet lines look like "- Key: value".
            guard trimmed.hasPrefix("-") else {
                // A non-bullet, non-blank line ends the block.
                if trimmed.isEmpty { continue }
                break
            }
            let entry = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = entry.firstIndex(of: ":") else { continue }
            let name = String(entry[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            fields.append(CustomField(name: name, value: value))
        }
        return fields
    }

    func serialized() -> String {
        var lines: [String] = []
        lines.append("Project: \(project)")
        if !issueType.isEmpty { lines.append("Issue type: \(issueType)") }
        lines.append("Summary: \(summary)")
        if !priority.isEmpty { lines.append("Priority: \(priority)") }
        if !labels.isEmpty { lines.append("Labels: \(ActionBodyParsing.joinList(labels))") }
        if !components.isEmpty { lines.append("Components: \(ActionBodyParsing.joinList(components))") }
        if let fixVersion { lines.append("Fix version: \(fixVersion)") }
        if let epicLink { lines.append("Epic link: \(epicLink)") }
        if let assignee { lines.append("Assignee: \(assignee)") }
        if !customFields.isEmpty {
            lines.append("Custom fields:")
            for field in customFields {
                lines.append("  - \(field.name): \(field.value)")
            }
        }
        lines.append("")
        lines.append("---DESCRIPTION---")
        lines.append(description)
        return lines.joined(separator: "\n")
    }
}
