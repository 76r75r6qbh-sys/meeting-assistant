import Foundation

/// Tiny helper for building Jira issue URLs from a bare issue key or from an
/// item's freeform `target` string. Used by the refinement-prep and ticket cards
/// to make story / issue keys clickable.
enum JiraLink {
    // NOTE: confirm Jira base URL — Medicore's cloud instance is assumed here.
    static let browseBase = "https://medicore.atlassian.net/browse/"

    /// Build a browse URL for a bare issue key (e.g. "IO-1234"). Trims whitespace
    /// and returns nil for empty / whitespace-only keys.
    static func url(forKey key: String) -> URL? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A key shouldn't contain spaces or slashes; reject obviously-bad input.
        guard !trimmed.contains(" ") else { return nil }
        return URL(string: browseBase + trimmed)
    }

    /// Prefer a full URL embedded in the item's `target` text; otherwise fall back
    /// to constructing a browse URL from the first issue-key-looking token.
    static func url(fromTarget target: String?) -> URL? {
        guard let target, !target.isEmpty else { return nil }
        if let embedded = ActionBodyParsing.firstURL(in: target),
           let url = URL(string: embedded) {
            return url
        }
        // No URL — look for an issue-key token like "IO-1234".
        if let key = firstIssueKey(in: target) {
            return url(forKey: key)
        }
        return nil
    }

    /// Extract the first token matching the Jira issue-key shape `ABC-123`.
    private static func firstIssueKey(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[A-Z][A-Z0-9]+-[0-9]+") else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range, in: text) else {
            return nil
        }
        return String(text[r])
    }
}
