import Foundation

struct TerminologyEntry: Equatable {
    let canonical: String
    let aliases: [String]
}

@MainActor
@Observable
final class TerminologyService {
    private(set) var isCorrecting = false
    var warningMessage: String?

    func clearWarning() {
        warningMessage = nil
    }

    static func parse(_ raw: String) -> [TerminologyEntry] {
        var entries: [TerminologyEntry] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let canonical = parts[0].trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }

            var aliases: [String] = []
            if parts.count == 2 {
                aliases = parts[1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            entries.append(TerminologyEntry(canonical: canonical, aliases: aliases))
        }
        return entries
    }

    static func dictionaryReplace(_ text: String, entries: [TerminologyEntry]) -> String {
        // Build (alias, canonical) pairs, sorted by alias length descending,
        // ties broken by entry order in `entries`.
        var pairs: [(alias: String, canonical: String, order: Int)] = []
        for (index, entry) in entries.enumerated() {
            for alias in entry.aliases {
                pairs.append((alias: alias, canonical: entry.canonical, order: index))
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.alias.count != rhs.alias.count {
                return lhs.alias.count > rhs.alias.count
            }
            return lhs.order < rhs.order
        }

        var result = text
        for pair in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: pair.alias)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            // escapedTemplate ensures `$`/`\` in the canonical aren't interpreted as backreferences.
            let template = NSRegularExpression.escapedTemplate(for: pair.canonical)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    static func formattedForPrompt(_ entries: [TerminologyEntry]) -> String {
        entries.map { "- \($0.canonical)" }.joined(separator: "\n")
    }

    static func renderTerminologyBlock(enabled: Bool, raw: String) -> String {
        guard enabled else { return "" }
        let entries = parse(raw)
        guard !entries.isEmpty else { return "" }
        return """
        Domain terminology to preserve (use these exact spellings):
        \(formattedForPrompt(entries))
        """
    }
}
