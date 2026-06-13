import Foundation

/// The part of a meeting that a search query matched.
enum ResultKind {
    case title
    case summary
    case transcript
    case notes
    case person
}

/// A single match produced by ``MeetingSearchIndex/search(_:in:)``.
///
/// `snippet` carries ~±40 characters of plain-text context around the first
/// match (no HTML — the view layer applies highlighting). `person` is non-nil
/// only when `kind == .person`.
struct SearchResult {
    let meeting: Meeting
    let kind: ResultKind
    let snippet: String?
    let person: String?
}

/// Pure, meeting-focused search over an in-memory collection of meetings.
///
/// No SwiftData fetches and no UI: callers pass the meetings to search and the
/// view layer renders the results. Action-queue results integrate separately at
/// the view layer.
enum MeetingSearchIndex {
    /// Characters of surrounding context to include on each side of a match.
    private static let snippetContext = 40

    static func search(_ query: String, in meetings: [Meeting]) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        var results: [SearchResult] = []

        for meeting in meetings {
            if meeting.title.lowercased().contains(needle) {
                results.append(SearchResult(meeting: meeting, kind: .title, snippet: nil, person: nil))
            }

            if let summary = meeting.summary, summary.lowercased().contains(needle) {
                results.append(SearchResult(
                    meeting: meeting,
                    kind: .summary,
                    snippet: snippet(from: summary, matching: needle),
                    person: nil
                ))
            }

            if let transcript = meeting.transcript, transcript.lowercased().contains(needle) {
                results.append(SearchResult(
                    meeting: meeting,
                    kind: .transcript,
                    snippet: snippet(from: transcript, matching: needle),
                    person: nil
                ))
            }

            if meeting.userNotes.lowercased().contains(needle) {
                results.append(SearchResult(
                    meeting: meeting,
                    kind: .notes,
                    snippet: snippet(from: meeting.userNotes, matching: needle),
                    person: nil
                ))
            }

            for participant in meeting.participants where participant.lowercased().contains(needle) {
                results.append(SearchResult(
                    meeting: meeting,
                    kind: .person,
                    snippet: nil,
                    person: participant
                ))
            }
        }

        return results
    }

    /// Returns ~±``snippetContext`` characters of context around the first
    /// case-insensitive occurrence of `needle` in `text`, clamped to string
    /// bounds. Returns `nil` if `needle` is not found.
    ///
    /// Internal (not private) so ``GlobalSearchViewModel`` reuses the exact same
    /// snippet extraction for its Tier 1 predicate matches.
    static func snippet(from text: String, matching needle: String) -> String? {
        guard let matchRange = text.range(of: needle, options: .caseInsensitive) else {
            return nil
        }

        let start = text.index(matchRange.lowerBound, offsetBy: -snippetContext, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(matchRange.upperBound, offsetBy: snippetContext, limitedBy: text.endIndex) ?? text.endIndex

        return String(text[start..<end])
    }
}
