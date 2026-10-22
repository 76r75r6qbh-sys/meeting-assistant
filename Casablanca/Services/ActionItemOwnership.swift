// Casablanca/Services/ActionItemOwnership.swift
import Foundation

/// Decides which summary action items belong to the user and should therefore
/// become to-dos. The summary prompt formats each item as
/// `**<owner>** — <action>`; items owned by other participants stay in the
/// summary (useful context) but no longer land on the user's to-do list.
///
/// Pure and stateless: preferences are read by the caller (see
/// `AppPreferences.userNameAliases` / `includeUnassignedActionItems`).
enum ActionItemOwnership {
    /// One action-item bullet split into its owner field and the action itself.
    struct ParsedItem: Equatable {
        /// Owner field with markdown stripped, or `nil` when the item has no
        /// owner (`**?**`, a placeholder like "unknown", or no recognizable
        /// `**owner** —` prefix at all).
        let owner: String?
        /// The action text without the owner prefix. For a line without a
        /// recognizable prefix this is the whole (trimmed) line.
        let action: String
    }

    /// Owner values that mean "nobody was assigned".
    private static let unassignedOwners: Set<String> = [
        "?", "??", "-", "unknown", "unassigned", "tbd", "nobody", "onbekend", "niemand", "nvt", "n.v.t.",
    ]

    /// Separators accepted between the bold owner and the action:
    /// em dash, en dash, hyphen and colon.
    private static let separators: [Character] = ["\u{2014}", "\u{2013}", "-", ":"]

    // MARK: - Parsing

    static func parse(_ line: String) -> ParsedItem {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Recognized shape: `**owner**` (optionally `**owner:**`) at the start,
        // then a separator, then the action.
        guard trimmed.hasPrefix("**") else { return ParsedItem(owner: nil, action: trimmed) }
        let afterOpen = trimmed.dropFirst(2)
        guard let close = afterOpen.range(of: "**") else { return ParsedItem(owner: nil, action: trimmed) }

        var owner = String(afterOpen[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = afterOpen[close.upperBound...].drop(while: { $0.isWhitespace })

        // `**Youri:** action` — the colon inside the bold acts as the separator.
        let colonInsideBold = owner.hasSuffix(":")
        if colonInsideBold {
            owner = String(owner.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if let first = rest.first, separators.contains(first) {
            rest = rest.dropFirst().drop(while: { $0.isWhitespace })
        } else if !colonInsideBold {
            // Bold text without a separator is emphasis, not an owner prefix.
            return ParsedItem(owner: nil, action: trimmed)
        }

        let action = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return ParsedItem(owner: nil, action: trimmed) }

        let cleanedOwner = owner
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleanedOwner.isEmpty || unassignedOwners.contains(fold(cleanedOwner)) {
            return ParsedItem(owner: nil, action: action)
        }
        return ParsedItem(owner: cleanedOwner, action: action)
    }

    // MARK: - Matching

    /// True when any of the (possibly several) owners in `owner` matches one of
    /// `aliases`. Matching is case- and diacritic-insensitive and works on whole
    /// word tokens: an alias matches when its tokens appear contiguously in the
    /// owner's tokens. So alias "Youri" matches "Youri B.", "Youri Broekhuizen"
    /// and "Kim & Youri", but not "Yourin". Multiple owners ("Youri & Kim",
    /// "Youri, Kim", "Youri en Kim", "Youri/Kim") need no special splitting:
    /// every separator is a non-letter and falls out of the tokenization.
    static func owner(_ owner: String, matchesAnyOf aliases: [String]) -> Bool {
        let ownerTokens = tokens(owner)
        guard !ownerTokens.isEmpty else { return false }
        for alias in aliases {
            let aliasTokens = tokens(alias)
            guard !aliasTokens.isEmpty, aliasTokens.count <= ownerTokens.count else { continue }
            for start in 0...(ownerTokens.count - aliasTokens.count)
            where Array(ownerTokens[start..<(start + aliasTokens.count)]) == aliasTokens {
                return true
            }
        }
        return false
    }

    // MARK: - To-do selection

    /// The to-do texts to create for a summary's action items: only the user's
    /// own items (plus unassigned ones when `includeUnassigned`), with the owner
    /// prefix stripped. Items whose text — in either the stripped or the original
    /// prefixed form — is already in `existing` are skipped, so re-summarizing a
    /// meeting whose to-dos were stored with the legacy prefix doesn't duplicate
    /// them. Duplicates within `items` are collapsed too.
    static func todoTexts(
        from items: [String],
        aliases: [String],
        includeUnassigned: Bool,
        existing: Set<String> = []
    ) -> [String] {
        var seen = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var result: [String] = []
        for item in items {
            let original = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { continue }
            let parsed = parse(original)
            let isMine: Bool
            if let owner = parsed.owner {
                isMine = Self.owner(owner, matchesAnyOf: aliases)
            } else {
                isMine = includeUnassigned
            }
            guard isMine, !parsed.action.isEmpty else { continue }
            guard !seen.contains(parsed.action), !seen.contains(original) else { continue }
            seen.insert(parsed.action)
            seen.insert(original)
            result.append(parsed.action)
        }
        return result
    }

    // MARK: - Normalization

    /// Lowercased and diacritics removed (`é` → `e`), whitespace-trimmed.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Folded word tokens: runs of letters/digits; everything else separates.
    static func tokens(_ text: String) -> [String] {
        fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
