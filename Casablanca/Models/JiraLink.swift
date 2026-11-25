import Foundation

/// Tiny helper for building Jira issue URLs from a bare issue key, to make
/// story / issue keys clickable. The Jira site is set in Settings → Draft
/// replies; the default is a placeholder.
enum JiraLink {
    static let defaultSiteURL = "https://your-site.atlassian.net"

    /// `<site>/browse/` for the configured site, or the default when the setting
    /// is empty or not an http(s) URL.
    static func browseBase(defaults: UserDefaults = .standard) -> String {
        var site = (defaults.string(forKey: AppPreferenceKey.jiraSiteURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isWebURL = URL(string: site).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false
        if site.isEmpty || !isWebURL { site = defaultSiteURL }
        while site.hasSuffix("/") { site.removeLast() }
        return site + "/browse/"
    }

    /// Build a browse URL for a bare issue key (e.g. "ABC-1234"). Trims whitespace
    /// and returns nil for empty / whitespace-only keys.
    static func url(forKey key: String, defaults: UserDefaults = .standard) -> URL? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A key shouldn't contain spaces or slashes; reject obviously-bad input.
        guard !trimmed.contains(" ") else { return nil }
        return URL(string: browseBase(defaults: defaults) + trimmed)
    }
}
