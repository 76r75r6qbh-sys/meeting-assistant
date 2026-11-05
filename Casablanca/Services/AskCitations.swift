import Foundation

/// Where a resolved citation points.
///
/// Phase 2 handoff: this is the value handed to the view's citation callback
/// (`AskCitationHandler`). Phase 1 opens `meetingID`; Phase 2 additionally
/// jumps to `seconds` in that meeting's transcript/audio. `seconds` is `nil`
/// when the citation had no time (summary / action-item sources) or its time
/// label could not be parsed.
struct AskCitationTarget: Equatable, Sendable {
    let meetingID: UUID
    let seconds: Double?
}

/// One citation parsed from a model answer.
struct AskCitation: Equatable, Sendable {
    /// The title as the model wrote it (commas kept).
    let title: String
    /// `yyyy-MM-dd` as written.
    let dateLabel: String
    /// `mm:ss` / `h:mm:ss` as written, or `nil`.
    let timeLabel: String?
    /// `nil` = unresolved: rendered as plain text, never as a link.
    let target: AskCitationTarget?

    /// The citation text as it appears inside the bracket.
    var label: String {
        if let timeLabel { return "\(title), \(dateLabel), \(timeLabel)" }
        return "\(title), \(dateLabel)"
    }
}

enum AskAnswerSegment: Equatable {
    case text(String)
    /// One bracket group, `raw` including its brackets, holding one or more
    /// citations (separated by `"; "` in `raw`).
    case citations(raw: String, [AskCitation])
}

/// Parses `[Meeting title, yyyy-MM-dd(, mm:ss)?]` citations out of an Ask
/// answer and resolves them against the sources that were in the prompt.
/// Pure; never traps: anything that does not parse or resolve stays text.
enum AskCitations {
    static let urlScheme = "casablanca-ask"
    private static let urlHost = "citation"
    private static let citationSeparator = "; "

    /// Greedy title so commas in titles stay in the title; anchored from the
    /// right on the date and optional time. ASCII digits only (`[0-9]`, not
    /// ICU `\d`) so the labels match what `AskCitationFormat` and
    /// `TranscriptLineFormat` produce.
    private static let citationPattern = try! NSRegularExpression(
        pattern: #"^(.+), ([0-9]{4}-[0-9]{2}-[0-9]{2})(?:, ([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?))?$"#
    )

    // MARK: - Parsing

    /// Splits `answer` into text and citation groups. Only a top-level,
    /// non-nested bracket group on one line is a candidate (see
    /// ``candidateGroups(in:)``); it becomes `.citations` only when every
    /// `"; "`-separated part is a citation, otherwise it stays text. Adjacent
    /// text segments are merged.
    static func segments(in answer: String, sources: [AskSource]) -> [AskAnswerSegment] {
        var result: [AskAnswerSegment] = []
        func appendText(_ text: Substring) {
            guard !text.isEmpty else { return }
            if case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + text)
            } else {
                result.append(.text(String(text)))
            }
        }

        let resolver = Resolver(sources: sources)
        var cursor = answer.startIndex
        for whole in candidateGroups(in: answer) {
            appendText(answer[cursor..<whole.lowerBound])
            let inner = answer[answer.index(after: whole.lowerBound)..<answer.index(before: whole.upperBound)]
            if let list = parseGroup(String(inner), resolver: resolver) {
                result.append(.citations(raw: String(answer[whole]), list))
            } else {
                appendText(answer[whole])
            }
            cursor = whole.upperBound
        }
        appendText(answer[cursor...])
        return result
    }

    /// Ranges (brackets included) of bracket groups that are not inside
    /// another bracket and contain no bracket themselves. A newline resets
    /// the bracket nesting, so an unterminated `[` only affects its own line;
    /// while it is open, no later group on that line is a candidate. A group
    /// with a nested bracket (`[x [A, d] y]`, `[[A, d]]`) is not a candidate,
    /// and neither is its inner group. A stray `]` is ignored.
    static func candidateGroups(in answer: String) -> [Range<String.Index>] {
        var groups: [Range<String.Index>] = []
        var open: [(start: String.Index, nested: Bool)] = []
        var index = answer.startIndex
        while index < answer.endIndex {
            let character = answer[index]
            if character.isNewline {
                open.removeAll()
            } else if character == "[" {
                if !open.isEmpty { open[open.count - 1].nested = true }
                open.append((index, false))
            } else if character == "]", let group = open.popLast() {
                if open.isEmpty {
                    if !group.nested { groups.append(group.start..<answer.index(after: index)) }
                } else {
                    open[open.count - 1].nested = true
                }
            }
            index = answer.index(after: index)
        }
        return groups
    }

    private static func parseGroup(_ inner: String, resolver: Resolver) -> [AskCitation]? {
        var list: [AskCitation] = []
        for part in inner.components(separatedBy: citationSeparator) {
            guard let citation = parseCitation(part, resolver: resolver) else { return nil }
            list.append(citation)
        }
        return list.isEmpty ? nil : list
    }

    private static func parseCitation(_ part: String, resolver: Resolver) -> AskCitation? {
        let range = NSRange(part.startIndex..., in: part)
        guard let match = citationPattern.firstMatch(in: part, range: range),
              let titleRange = Range(match.range(at: 1), in: part),
              let dateRange = Range(match.range(at: 2), in: part) else { return nil }
        let title = String(part[titleRange])
        let date = String(part[dateRange])
        let time = Range(match.range(at: 3), in: part).map { String(part[$0]) }
        let target = resolver.meetingID(title: title, dateLabel: date).map { meetingID in
            AskCitationTarget(meetingID: meetingID, seconds: time.flatMap(seconds(fromTimeLabel:)))
        }
        return AskCitation(title: title, dateLabel: date, timeLabel: time, target: target)
    }

    /// `TranscriptLineFormat.seconds(fromLabel:)`, but `nil` when a minutes
    /// (in `h:mm:ss`) or seconds field is 60 or more (`99:99`). Such a
    /// citation still resolves its meeting; only the jump time is dropped.
    static func seconds(fromTimeLabel label: String) -> Double? {
        let fields = label.split(separator: ":").dropFirst()
        guard fields.allSatisfy({ (Int($0) ?? 60) < 60 }) else { return nil }
        return TranscriptLineFormat.seconds(fromLabel: label)
    }

    /// Resolution against the prompt's sources only: exact match on folded
    /// title + date label; else the single source meeting on that date, but
    /// only when the titles are similar (``titlesAreSimilar(_:_:)``); else
    /// `nil`. More than one distinct meeting at either step is ambiguous and
    /// stays unresolved, so a citation never links to a wrong meeting.
    private struct Resolver {
        private var byTitleAndDate: [String: Set<UUID>] = [:]
        /// Date label → meeting → its citation title.
        private var byDate: [String: [UUID: String]] = [:]

        init(sources: [AskSource]) {
            for source in sources {
                byTitleAndDate[Self.key(source.meetingTitle, source.dateLabel), default: []].insert(source.meetingID)
                byDate[source.dateLabel, default: [:]][source.meetingID] = source.meetingTitle
            }
        }

        func meetingID(title: String, dateLabel: String) -> UUID? {
            if let exact = byTitleAndDate[Self.key(title, dateLabel)] {
                return exact.count == 1 ? exact.first : nil
            }
            if let sameDay = byDate[dateLabel], sameDay.count == 1, let only = sameDay.first,
               AskCitations.titlesAreSimilar(title, only.value) {
                return only.key
            }
            return nil
        }

        private static func key(_ title: String, _ dateLabel: String) -> String {
            AskTokenizer.fold(title.trimmingCharacters(in: .whitespaces)) + "\n" + dateLabel
        }
    }

    /// Same-date fallback guard. On `AskTokenizer.tokens` (folded, stopwords
    /// and 1-letter tokens dropped) as sets, both non-empty: one is a subset
    /// of the other, or their Jaccard index is at least 0.5.
    static func titlesAreSimilar(_ cited: String, _ source: String) -> Bool {
        let a = Set(AskTokenizer.tokens(cited))
        let b = Set(AskTokenizer.tokens(source))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.isSubset(of: b) || b.isSubset(of: a) { return true }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.5
    }

    // MARK: - Rendering

    /// The answer as an `AttributedString`. Each resolved citation's label
    /// (inside the bracket) gets `.link = url(for: n)` with `n` numbering the
    /// resolved citations 0, 1, … in order; `targets[n]` is its target.
    /// Brackets, separators and unresolved citations are plain text. The
    /// characters equal the original answer.
    static func attributed(_ segments: [AskAnswerSegment]) -> (text: AttributedString, targets: [Int: AskCitationTarget]) {
        var text = AttributedString()
        var targets: [Int: AskCitationTarget] = [:]
        for segment in segments {
            switch segment {
            case let .text(plain):
                text += AttributedString(plain)
            case let .citations(raw, list):
                guard list.contains(where: { $0.target != nil }) else {
                    text += AttributedString(raw)
                    continue
                }
                text += AttributedString("[")
                for (offset, citation) in list.enumerated() {
                    if offset > 0 { text += AttributedString(citationSeparator) }
                    var piece = AttributedString(citation.label)
                    if let target = citation.target {
                        let index = targets.count
                        targets[index] = target
                        piece.link = url(for: index)
                    }
                    text += piece
                }
                text += AttributedString("]")
            }
        }
        return (text, targets)
    }

    // MARK: - URLs

    /// `casablanca-ask://citation/<index>`.
    static func url(for index: Int) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        components.path = "/\(index)"
        // Scheme, host and a numeric path always form a valid URL.
        return components.url!
    }

    /// The index in a ``url(for:)`` URL; `nil` for other schemes, hosts or
    /// malformed paths.
    static func index(from url: URL) -> Int? {
        guard url.scheme?.lowercased() == urlScheme,
              url.host?.lowercased() == urlHost else { return nil }
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        let digits = path.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }
}
