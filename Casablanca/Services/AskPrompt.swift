import Foundation

/// One excerpt that was put in an Ask prompt. Citations in the model's answer
/// are resolved only against these.
struct AskSource: Identifiable, Equatable, Sendable {
    /// 1-based source number, in selection order.
    let id: Int
    let meetingID: UUID
    /// The meeting title after ``AskCitationFormat/citationTitle(_:)``.
    let meetingTitle: String
    /// `yyyy-MM-dd` (``AskCitationFormat/dateLabel(_:calendar:)``).
    let dateLabel: String
    /// `mm:ss` / `h:mm:ss`, or `nil` for sources without a time.
    let timeLabel: String?
    let kind: AskChunkKind
    let text: String

    /// `[<title>, <date>, <time>]`, or `[<title>, <date>]` without a time.
    var citation: String {
        if let timeLabel {
            return "[\(meetingTitle), \(dateLabel), \(timeLabel)]"
        }
        return "[\(meetingTitle), \(dateLabel)]"
    }
}

/// Formatting shared by the prompt's source headers and the citation parser.
enum AskCitationFormat {
    /// Title used when a meeting title is empty after sanitising (matches the
    /// app's "Untitled Meeting" fallback for calendar events).
    static let untitledTitle = "Untitled Meeting"

    /// `[` → `(`, `]` → `)`, `;` → `,`, every newline → a space, then
    /// trimmed, so a title can never open or close a citation bracket nor
    /// split a multi-citation bracket (citations are joined with `"; "`).
    /// An empty result becomes ``untitledTitle``.
    static func citationTitle(_ title: String) -> String {
        let mapped = title.map { character -> Character in
            if character == "[" { return "(" }
            if character == "]" { return ")" }
            if character == ";" { return "," }
            if character.isNewline { return " " }
            return character
        }
        let trimmed = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledTitle : trimmed
    }

    /// `yyyy-MM-dd` of `date` in `calendar` (and its time zone).
    ///
    /// Source headers and citations use the calendar passed to
    /// ``AskPrompt/selectSources(_:meetings:question:filter:tokenBudget:calendar:)``
    /// (default `Calendar.current`). Resolve citations against the returned
    /// ``AskSource/dateLabel`` values, or recompute labels with that same
    /// calendar; a different time zone can shift the date by a day.
    static func dateLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Budgeted source selection and the single-turn Ask prompt. Pure; no
/// main-actor requirement.
enum AskPrompt {
    static let systemFraming = """
    You answer questions about the user's past meetings. Use ONLY the sources below: excerpts from meeting summaries, extracted action items and transcripts. If the sources do not contain the answer, say so plainly (for example "Ik kan dat niet vinden in je meetings." or "I can't find that in your meetings.") instead of guessing. Do not use outside knowledge.

    Answer in the language of the question. Start with a short, direct answer; add supporting points only when they help.

    Cite every factual claim with the citation shown in the header of the source it came from, copied exactly, for example [Refinement Team Link, 2026-11-03, 12:34]. Some sources have no time; cite those as shown, for example [Refinement Team Link, 2026-11-03]. Several citations for one claim go in one bracket separated by "; ". Never invent a citation, never cite a source number, and never cite a meeting that is not in the sources.

    When sources disagree, say so and cite both; the most recent meeting usually reflects the current state. In transcript lines, a speaker label before a colon ("Youri: ...") is the person who said it. Action item sources state the owner only when someone was explicitly assigned; do not assign owners yourself.
    """

    static let maxSourcesPerMeeting = 4
    /// How many chunks to retrieve, and the most sources one prompt holds.
    static let retrievalLimit = 60
    /// Output is capped separately by `maxTokens`, so the prompt may use the
    /// whole budget.
    static let answerReserveTokens = 0
    /// Minimum text kept when the first chunk alone is larger than the budget.
    static let minTruncatedChars = 200

    static let noSourcesMarker = "(No matching meeting content was found.)"
    private static let blockSeparator = "\n\n"
    private static let ellipsis = "…"

    // MARK: - Selection

    /// Walks `scored` in order and keeps each chunk whose source block still
    /// fits `tokenBudget` (estimated with `LLMPromptSupport.budgetTokens`),
    /// at most ``maxSourcesPerMeeting`` per meeting and ``retrievalLimit`` in
    /// all. A chunk that does not fit is skipped, not a stop, so smaller later
    /// chunks can still enter. Chunks whose meeting is missing from `meetings`
    /// are skipped. When nothing fits, the first usable chunk is included with
    /// its text cut to the remaining budget (at least ``minTruncatedChars``
    /// characters) and `…` appended. Ids are 1…n in selection order.
    static func selectSources(
        _ scored: [ScoredChunk],
        meetings: [UUID: AskMeetingSnapshot],
        question: String,
        filter: AskFilter,
        tokenBudget: Int,
        calendar: Calendar = .current
    ) -> [AskSource] {
        let budget = tokenBudget - answerReserveTokens
        let fixed = LLMPromptSupport.budgetTokens(render(question: question, filter: filter, sources: [], calendar: calendar))
        var used = fixed
        var perMeeting: [UUID: Int] = [:]
        var selected: [AskSource] = []

        for item in scored {
            guard selected.count < retrievalLimit else { break }
            let chunk = item.chunk
            guard let meeting = meetings[chunk.meetingID] else { continue }
            guard perMeeting[chunk.meetingID, default: 0] < maxSourcesPerMeeting else { continue }

            let source = makeSource(id: selected.count + 1, chunk: chunk, meeting: meeting, text: chunk.text, calendar: calendar)
            let cost = blockCost(source)
            guard used + cost <= budget else { continue }
            used += cost
            perMeeting[chunk.meetingID, default: 0] += 1
            selected.append(source)
        }

        if selected.isEmpty,
           let first = scored.first(where: { meetings[$0.chunk.meetingID] != nil }),
           let meeting = meetings[first.chunk.meetingID] {
            let header = makeSource(id: 1, chunk: first.chunk, meeting: meeting, text: "", calendar: calendar)
            let remainingChars = max(0, budget - fixed) * LLMPromptSupport.budgetCharsPerToken
            let overhead = block(header).count + blockSeparator.count + ellipsis.count
            let keep = max(minTruncatedChars, remainingChars - overhead)
            selected = [makeSource(id: 1, chunk: first.chunk, meeting: meeting, text: truncated(first.chunk.text, keep: keep),
                                   calendar: calendar)]
        }
        return selected
    }

    // MARK: - Render

    /// Framing, optional `## Filters`, `## Sources` and `## Question`,
    /// separated by one blank line. `calendar` only formats the filter's dates.
    static func render(question: String, filter: AskFilter, sources: [AskSource],
                       calendar: Calendar = .current) -> String {
        var sections = [systemFraming]

        let filterLines = filterLines(filter, calendar: calendar)
        if !filterLines.isEmpty {
            sections.append((["## Filters"] + filterLines).joined(separator: "\n"))
        }

        let body = sources.isEmpty ? noSourcesMarker : sources.map(block).joined(separator: blockSeparator)
        sections.append("## Sources\n" + body)
        sections.append("## Question\n" + question.trimmingCharacters(in: .whitespacesAndNewlines))
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Private

    private static func makeSource(id: Int, chunk: AskChunk, meeting: AskMeetingSnapshot, text: String,
                                   calendar: Calendar) -> AskSource {
        AskSource(
            id: id,
            meetingID: chunk.meetingID,
            meetingTitle: AskCitationFormat.citationTitle(meeting.title),
            dateLabel: AskCitationFormat.dateLabel(meeting.date, calendar: calendar),
            timeLabel: chunk.timeLabel,
            kind: chunk.kind,
            text: text
        )
    }

    /// `### Source <n> | Cite as: <citation> | <kind>` and the text.
    private static func block(_ source: AskSource) -> String {
        "### Source \(source.id) | Cite as: \(source.citation) | \(kindLabel(source.kind))\n\(source.text)"
    }

    /// A block plus its separator. Counting the separator with every block
    /// keeps the sum an upper bound for the rendered prompt: the blocks
    /// replace the no-sources marker and need one separator fewer than
    /// blocks, and `budgetTokens` (a ceiling) is subadditive.
    private static func blockCost(_ source: AskSource) -> Int {
        LLMPromptSupport.budgetTokens(forCharCount: block(source).count + blockSeparator.count)
    }

    private static func kindLabel(_ kind: AskChunkKind) -> String {
        switch kind {
        case .summary: return "summary"
        case .actionItem: return "action item"
        case .transcript: return "transcript"
        }
    }

    private static func filterLines(_ filter: AskFilter, calendar: Calendar) -> [String] {
        guard !filter.isEmpty else { return [] }
        var lines: [String] = []
        switch (filter.from, filter.to) {
        case let (from?, to?):
            lines.append("Date range: \(AskCitationFormat.dateLabel(from, calendar: calendar)) to \(AskCitationFormat.dateLabel(to, calendar: calendar))")
        case let (from?, nil):
            lines.append("Date range: from \(AskCitationFormat.dateLabel(from, calendar: calendar))")
        case let (nil, to?):
            lines.append("Date range: up to \(AskCitationFormat.dateLabel(to, calendar: calendar))")
        case (nil, nil):
            break
        }
        if let participant = criterion(filter.participant) { lines.append("Participant: \(participant)") }
        if let tag = criterion(filter.tag) { lines.append("Tag: \(tag)") }
        return lines
    }

    private static func criterion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The first `keep` characters (trailing whitespace dropped) plus `…`;
    /// text that already fits is returned unchanged.
    private static func truncated(_ text: String, keep: Int) -> String {
        guard text.count > keep else { return text }
        let prefix = String(text.prefix(keep))
        let trimmed = prefix.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trimmed + ellipsis
    }
}
