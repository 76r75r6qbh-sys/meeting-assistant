import Foundation

// MARK: - Shared parsing helpers

/// Pure, UI-free helpers shared by the per-bucket action-card body parsers.
///
/// The action-queue `body` field is freeform text. Each bucket follows a
/// structured convention (see action-queue-schema.md, "Body conventions per
/// bucket"). These helpers parse `Key: value` header lines case-insensitively,
/// trim whitespace, tolerate field reordering and blank lines, and split
/// comma-separated list fields into `[String]`.
enum ActionBodyParsing {
    /// Normalize line endings to `\n`. Action-queue bodies can originate from
    /// Outlook/Teams (CRLF) or lone-CR sources; left untrimmed, the trailing
    /// `\r` corrupts blank-line and `---DELIMITER---` detection. Every
    /// `init?(parsing:)` entry point normalizes once at the boundary so all the
    /// shared helpers below see clean `\n`-separated text.
    static func normalizeNewlines(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Split a comma-separated field into trimmed, non-empty components.
    static func list(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Serialize a `[String]` list field back to a comma-joined value.
    static func joinList(_ items: [String]) -> String {
        items.joined(separator: ", ")
    }

    /// Parse `Key: value` header lines into a case-insensitive lookup, stopping
    /// at the first occurrence of `delimiter` (e.g. `---DESCRIPTION---`) if one
    /// is given. Returns the parsed headers plus the verbatim text that followed
    /// the delimiter line (or `nil` if no delimiter was supplied / found).
    ///
    /// Keys are lowercased for lookup. The *first* occurrence of a key wins.
    static func parseHeaders(
        _ body: String,
        bodyDelimiter delimiter: String? = nil
    ) -> (headers: HeaderMap, afterDelimiter: String?) {
        let lines = body.components(separatedBy: "\n")
        var headers = HeaderMap()
        var after: String?

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let delimiter, line.trimmingCharacters(in: .whitespacesAndNewlines) == delimiter {
                // Everything after this line, verbatim (re-joined with newlines).
                let rest = lines[(index + 1)...]
                after = rest.joined(separator: "\n")
                break
            }
            headers.consume(line: line)
            index += 1
        }
        return (headers, after)
    }

    /// Extract the email body that follows the first blank line, verbatim
    /// (internal blank lines preserved). Returns "" when there is no blank line.
    static func bodyAfterFirstBlankLine(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard let blankIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return ""
        }
        let rest = lines[(blankIndex + 1)...]
        return rest.joined(separator: "\n")
    }

    /// Extract the first http(s) URL found in a line, if any.
    static func firstURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let match = detector.firstMatch(in: text, options: [], range: range)
        guard let match, let url = match.url else { return nil }
        return url.absoluteString
    }
}

/// Case-insensitive store of `Key: value` header lines.
struct HeaderMap {
    private var storage: [String: String] = [:]

    mutating func consume(line: String) {
        guard let colon = line.firstIndex(of: ":") else { return }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        let valueStart = line.index(after: colon)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // First occurrence wins.
        if storage[key] == nil {
            storage[key] = value
        }
    }

    /// Lookup by key (case-insensitive). Returns nil if absent.
    subscript(_ key: String) -> String? {
        storage[key.lowercased()]
    }

    /// Non-empty value or nil.
    func nonEmpty(_ key: String) -> String? {
        guard let value = self[key], !value.isEmpty else { return nil }
        return value
    }
}
