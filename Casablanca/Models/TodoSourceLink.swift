import Foundation

/// A to-do's source link: the raw `scheme:ref` a to-do line carries after
/// `🔗` (stored as ``TodoItem/sourceRef``), with a label to show and, where
/// one exists, a URL to open.
struct TodoSourceLink: Equatable {
    enum Scheme: String, CaseIterable {
        case outlook, teams, jira, topdesk, url
    }

    let scheme: Scheme
    let ref: String

    /// Splits `raw` at its first `:`. Nil for an unknown scheme or an empty ref.
    init?(_ raw: String) {
        guard let colon = raw.firstIndex(of: ":"),
              let scheme = Scheme(rawValue: String(raw[..<colon]))
        else { return nil }
        let ref = String(raw[raw.index(after: colon)...])
        guard !ref.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.scheme = scheme
        self.ref = ref
    }

    var label: String {
        switch scheme {
        case .outlook: "Outlook email"
        case .teams: "Teams chat"
        case .jira: "Jira \(ref)"
        case .topdesk: "Topdesk \(ref)"
        case .url: webURL?.host() ?? ref
        }
    }

    /// The page to open: a Jira issue, or a web link. Outlook, Teams and
    /// Topdesk refs have no URL of their own.
    var url: URL? {
        switch scheme {
        case .jira: JiraLink.url(forKey: ref)
        case .url: webURL
        case .outlook, .teams, .topdesk: nil
        }
    }

    /// `ref` as an http(s) URL with a host. Other schemes (`file:`, app
    /// schemes) are never opened from a to-do line.
    private var webURL: URL? {
        guard let url = URL(string: ref),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
