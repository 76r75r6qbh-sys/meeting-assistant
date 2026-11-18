import Foundation

/// Tiny helper for building Jira issue URLs from a bare issue key, to make
/// story / issue keys clickable.
enum JiraLink {
    static let browseBase = "https://tenzinger.atlassian.net/browse/"

    /// Build a browse URL for a bare issue key (e.g. "IO-1234"). Trims whitespace
    /// and returns nil for empty / whitespace-only keys.
    static func url(forKey key: String) -> URL? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A key shouldn't contain spaces or slashes; reject obviously-bad input.
        guard !trimmed.contains(" ") else { return nil }
        return URL(string: browseBase + trimmed)
    }
}
