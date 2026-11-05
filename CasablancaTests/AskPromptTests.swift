import Foundation
import XCTest
@testable import Casablanca

final class AskPromptTests: XCTestCase {

    // MARK: - Helpers

    /// Noon UTC, so the `yyyy-MM-dd` label is the same in every time zone
    /// from UTC-11 to UTC+11 (the default calendar is `.current`).
    private func noonUTC(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: 12))!
    }

    private func snapshot(id: UUID = UUID(), title: String = "T", date: Date? = nil) -> AskMeetingSnapshot {
        AskMeetingSnapshot(
            id: id, title: title, date: date ?? noonUTC(2026, 11, 3), participants: [], tags: [],
            summary: nil, actionItems: [], transcript: nil
        )
    }

    private func scored(_ meeting: UUID, _ n: Int, kind: AskChunkKind = .transcript,
                        text: String, time: String? = "12:34", score: Double = 1) -> ScoredChunk {
        ScoredChunk(
            chunk: AskChunk(id: "\(meeting.uuidString)#\(kind.rawValue)#\(n)", meetingID: meeting,
                            kind: kind, text: text, timeLabel: time),
            score: score
        )
    }

    /// About `tokens` budget tokens of text (3 chars per token).
    private func text(tokens: Int, seed: Int = 0) -> String {
        let word = "woord\(seed) "
        var s = ""
        while s.count < tokens * LLMPromptSupport.budgetCharsPerToken { s += word }
        return String(s.prefix(tokens * LLMPromptSupport.budgetCharsPerToken))
    }

    private func source(_ id: Int, kind: AskChunkKind, time: String?, text: String) -> AskSource {
        AskSource(id: id, meetingID: UUID(), meetingTitle: "T", dateLabel: "2026-11-03",
                  timeLabel: time, kind: kind, text: text)
    }

    /// `count` meetings with `perMeeting` chunks each, interleaved so the
    /// per-meeting cap does not dominate.
    private func corpus(meetings count: Int, perMeeting: Int, tokens: Int)
        -> (scored: [ScoredChunk], meetings: [UUID: AskMeetingSnapshot]) {
        let snaps = (0..<count).map { i in snapshot(title: "Meeting \(i)") }
        var result: [ScoredChunk] = []
        for n in 0..<perMeeting {
            for (i, snap) in snaps.enumerated() {
                result.append(scored(snap.id, n, text: text(tokens: tokens, seed: i * 100 + n),
                                     score: Double(10_000 - result.count)))
            }
        }
        return (result, Dictionary(uniqueKeysWithValues: snaps.map { ($0.id, $0) }))
    }

    // MARK: - Framing and render

    func testFramingIsExact() {
        let expected = """
        You answer questions about the user's past meetings. Use ONLY the sources below: excerpts from meeting summaries, extracted action items and transcripts. If the sources do not contain the answer, say so plainly (for example "Ik kan dat niet vinden in je meetings." or "I can't find that in your meetings.") instead of guessing. Do not use outside knowledge.

        Answer in the language of the question. Start with a short, direct answer; add supporting points only when they help.

        Cite every factual claim with the citation shown in the header of the source it came from, copied exactly, for example [Refinement Team Link, 2026-11-03, 12:34]. Some sources have no time; cite those as shown, for example [Refinement Team Link, 2026-11-03]. Several citations for one claim go in one bracket separated by "; ". Never invent a citation, never cite a source number, and never cite a meeting that is not in the sources.

        When sources disagree, say so and cite both; the most recent meeting usually reflects the current state. In transcript lines, a speaker label before a colon ("Youri: ...") is the person who said it. Action item sources state the owner only when someone was explicitly assigned; do not assign owners yourself.
        """
        XCTAssertEqual(AskPrompt.systemFraming, expected)
        XCTAssertTrue(AskPrompt.systemFraming.hasPrefix("You answer questions about the user's past meetings."))
        XCTAssertTrue(AskPrompt.systemFraming.contains("[Refinement Team Link, 2026-11-03, 12:34]"))
        // Ruling R8: old transcripts contain "[00:10] Agenda: punt 1".
        XCTAssertFalse(AskPrompt.systemFraming.contains("a name before a colon"))
    }

    func testRenderLayout() {
        let sources = [
            source(1, kind: .transcript, time: "12:34", text: "Youri: we kiezen v2"),
            source(2, kind: .summary, time: nil, text: "## Decisions\n- v2"),
        ]
        let prompt = AskPrompt.render(question: "wat is besloten?", filter: .none, sources: sources)

        let expected = AskPrompt.systemFraming + "\n\n"
            + "## Sources\n"
            + "### Source 1 | Cite as: [T, 2026-11-03, 12:34] | transcript\nYouri: we kiezen v2\n\n"
            + "### Source 2 | Cite as: [T, 2026-11-03] | summary\n## Decisions\n- v2\n\n"
            + "## Question\nwat is besloten?"
        XCTAssertEqual(prompt, expected)
        XCTAssertTrue(prompt.contains("### Source 1 | Cite as: [T, 2026-11-03, 12:34] | transcript"))
        XCTAssertTrue(prompt.contains("### Source 2 | Cite as: [T, 2026-11-03] | summary"))
        XCTAssertTrue(prompt.hasSuffix("## Question\nwat is besloten?"))
        XCTAssertFalse(prompt.contains("## Filters"))
    }

    func testActionItemKindLabel() {
        let prompt = AskPrompt.render(
            question: "q", filter: .none,
            sources: [source(1, kind: .actionItem, time: nil, text: "Action item: x — owner: unassigned")]
        )
        XCTAssertTrue(prompt.contains("### Source 1 | Cite as: [T, 2026-11-03] | action item\nAction item: x"))
    }

    func testRenderFilters() {
        let filter = AskFilter(from: nil, to: nil, participant: " Kim ", tag: "partner")
        let prompt = AskPrompt.render(question: "q", filter: filter, sources: [])
        XCTAssertTrue(prompt.contains(AskPrompt.systemFraming + "\n\n## Filters\nParticipant: Kim\nTag: partner\n\n## Sources\n"))
        XCTAssertFalse(prompt.contains("Date range"))
    }

    func testRenderDateRangeFilter() {
        let filter = AskFilter(from: noonUTC(2026, 10, 1), to: noonUTC(2026, 11, 5), participant: "  ", tag: nil)
        let prompt = AskPrompt.render(question: "q", filter: filter, sources: [])
        XCTAssertTrue(prompt.contains("## Filters\nDate range: 2026-10-01 to 2026-11-05\n\n## Sources"))
        XCTAssertFalse(prompt.contains("Participant:"))
    }

    func testNoSourcesMarker() {
        let prompt = AskPrompt.render(question: " wie? \n", filter: .none, sources: [])
        XCTAssertEqual(
            prompt,
            AskPrompt.systemFraming + "\n\n## Sources\n(No matching meeting content was found.)\n\n## Question\nwie?"
        )
    }

    // MARK: - Citation format

    func testCitationTitleSanitises() {
        XCTAssertEqual(AskCitationFormat.citationTitle("Bila [extern]\nx"), "Bila (extern) x")
        XCTAssertEqual(AskCitationFormat.citationTitle("  a\r\nb  "), "a b")
        XCTAssertEqual(AskCitationFormat.citationTitle("Bila Youri, Martijn"), "Bila Youri, Martijn")
        XCTAssertEqual(AskCitationFormat.citationTitle("Sprint review; demo"), "Sprint review, demo")
        XCTAssertFalse(AskCitationFormat.citationTitle("a;b;;c").contains(";"))
    }

    func testEmptyCitationTitleFallsBackToUntitled() {
        XCTAssertEqual(AskCitationFormat.citationTitle(""), "Untitled Meeting")
        XCTAssertEqual(AskCitationFormat.citationTitle("  \n\t "), "Untitled Meeting")
        let m = snapshot(title: " \n ")
        let sources = AskPrompt.selectSources([scored(m.id, 0, kind: .summary, text: "s", time: nil)],
                                              meetings: [m.id: m], question: "q", filter: .none, tokenBudget: 6_000)
        XCTAssertEqual(sources.first?.citation, "[Untitled Meeting, 2026-11-03]")
    }

    func testSelectionUsesInjectedCalendar() {
        var ams = Calendar(identifier: .gregorian)
        ams.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 23:30 UTC on 2026-11-03 = 00:30 on 2026-11-04 in Amsterdam.
        let m = snapshot(date: noonUTC(2026, 11, 3).addingTimeInterval(11.5 * 3600))
        let chunk = [scored(m.id, 0, text: "t", time: "00:10")]
        XCTAssertEqual(AskPrompt.selectSources(chunk, meetings: [m.id: m], question: "q", filter: .none,
                                               tokenBudget: 6_000, calendar: ams).first?.dateLabel, "2026-11-04")
        XCTAssertEqual(AskPrompt.selectSources(chunk, meetings: [m.id: m], question: "q", filter: .none,
                                               tokenBudget: 6_000, calendar: utc).first?.dateLabel, "2026-11-03")
        let filter = AskFilter(from: m.date, to: nil, participant: nil, tag: nil)
        XCTAssertTrue(AskPrompt.render(question: "q", filter: filter, sources: [], calendar: ams)
            .contains("Date range: from 2026-11-04"))
    }

    func testDateLabelUsesCalendarTimeZone() {
        var ams = Calendar(identifier: .gregorian)
        ams.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // 23:30 UTC on 2026-11-03 is 00:30 on 2026-11-04 in Amsterdam.
        let date = noonUTC(2026, 11, 3).addingTimeInterval(11.5 * 3600)
        XCTAssertEqual(AskCitationFormat.dateLabel(date, calendar: ams), "2026-11-04")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(AskCitationFormat.dateLabel(date, calendar: utc), "2026-11-03")
    }

    func testSourceCitation() {
        XCTAssertEqual(source(1, kind: .transcript, time: "1:02:03", text: "").citation, "[T, 2026-11-03, 1:02:03]")
        XCTAssertEqual(source(1, kind: .summary, time: nil, text: "").citation, "[T, 2026-11-03]")
    }

    // MARK: - Selection

    func testSelectionRespectsBudget() {
        let (chunks, meetings) = corpus(meetings: 25, perMeeting: 4, tokens: 300)
        XCTAssertEqual(chunks.count, 100)
        let sources = AskPrompt.selectSources(chunks, meetings: meetings, question: "wat is besloten?",
                                              filter: .none, tokenBudget: 6_000)
        XCTAssertGreaterThanOrEqual(sources.count, 1)
        let prompt = AskPrompt.render(question: "wat is besloten?", filter: .none, sources: sources)
        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(prompt), 6_000)
    }

    func testPerMeetingCap() {
        let a = snapshot(title: "A"), b = snapshot(title: "B")
        var chunks = (0..<10).map { scored(a.id, $0, text: "a\($0)", score: Double(100 - $0)) }
        chunks.append(scored(b.id, 0, text: "b0", score: 1))
        let sources = AskPrompt.selectSources(chunks, meetings: [a.id: a, b.id: b], question: "q",
                                              filter: .none, tokenBudget: 100_000)
        XCTAssertEqual(sources.filter { $0.meetingID == a.id }.count, AskPrompt.maxSourcesPerMeeting)
        XCTAssertEqual(sources.filter { $0.meetingID == a.id }.map(\.text), ["a0", "a1", "a2", "a3"])
        XCTAssertEqual(sources.filter { $0.meetingID == b.id }.map(\.text), ["b0"])
    }

    func testSkipsTooLargeButKeepsSmallerLater() {
        let m = snapshot()
        let fixed = LLMPromptSupport.budgetTokens(AskPrompt.render(question: "q", filter: .none, sources: []))
        let budget = fixed + 500
        let chunks = [
            scored(m.id, 0, text: text(tokens: 200, seed: 0)),
            scored(m.id, 1, text: text(tokens: 2_000, seed: 1)),
            scored(m.id, 2, text: text(tokens: 200, seed: 2)),
        ]
        let sources = AskPrompt.selectSources(chunks, meetings: [m.id: m], question: "q",
                                              filter: .none, tokenBudget: budget)
        XCTAssertEqual(sources.map(\.text), [chunks[0].chunk.text, chunks[2].chunk.text])
        XCTAssertLessThanOrEqual(
            LLMPromptSupport.budgetTokens(AskPrompt.render(question: "q", filter: .none, sources: sources)), budget)
    }

    func testOversizedFirstChunkIsTruncatedNotDropped() {
        let m = snapshot(title: "Refinement Team Link")
        let big = text(tokens: 20_000)
        let sources = AskPrompt.selectSources([scored(m.id, 0, text: big)], meetings: [m.id: m],
                                              question: "q", filter: .none, tokenBudget: 6_000)
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(sources[0].text.hasSuffix("…"))
        XCTAssertTrue(big.hasPrefix(String(sources[0].text.dropLast())))
        XCTAssertGreaterThan(sources[0].text.count, 1_000)
        XCTAssertLessThanOrEqual(
            LLMPromptSupport.budgetTokens(AskPrompt.render(question: "q", filter: .none, sources: sources)), 6_000)
    }

    func testOversizedFirstChunkKeepsMinimumText() {
        let m = snapshot()
        let fixed = LLMPromptSupport.budgetTokens(AskPrompt.render(question: "q", filter: .none, sources: []))
        let sources = AskPrompt.selectSources([scored(m.id, 0, text: text(tokens: 1_000))], meetings: [m.id: m],
                                              question: "q", filter: .none, tokenBudget: fixed + 10)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].text.count, AskPrompt.minTruncatedChars + 1)
        XCTAssertTrue(sources[0].text.hasSuffix("…"))
    }

    func testLargeBudgetTakesMoreSources() {
        let (chunks, meetings) = corpus(meetings: 25, perMeeting: 4, tokens: 300)
        let small = AskPrompt.selectSources(chunks, meetings: meetings, question: "q", filter: .none, tokenBudget: 6_000)
        let large = AskPrompt.selectSources(chunks, meetings: meetings, question: "q", filter: .none, tokenBudget: 150_000)
        XCTAssertGreaterThan(large.count, small.count)
        XCTAssertEqual(large.count, AskPrompt.retrievalLimit)
        XCTAssertLessThanOrEqual(
            LLMPromptSupport.budgetTokens(AskPrompt.render(question: "q", filter: .none, sources: large)), 150_000)
    }

    func testSourceIdsSequential() {
        let a = snapshot(title: "Bila [extern]"), b = snapshot(title: "B", date: noonUTC(2026, 10, 1))
        let chunks = [
            scored(a.id, 0, kind: .summary, text: "s", time: nil),
            scored(UUID(), 0, text: "unknown meeting"),
            scored(b.id, 0, text: "t", time: "00:10"),
            scored(a.id, 1, kind: .actionItem, text: "ai", time: nil),
        ]
        let sources = AskPrompt.selectSources(chunks, meetings: [a.id: a, b.id: b], question: "q",
                                              filter: .none, tokenBudget: 100_000)
        XCTAssertEqual(sources.map(\.id), [1, 2, 3])
        XCTAssertEqual(sources.map(\.text), ["s", "t", "ai"])
        XCTAssertEqual(sources[0].citation, "[Bila (extern), 2026-11-03]")
        XCTAssertEqual(sources[1].citation, "[B, 2026-10-01, 00:10]")
        XCTAssertEqual(sources[2].kind, .actionItem)
    }

    func testEmptyScoredYieldsNoSources() {
        XCTAssertEqual(AskPrompt.selectSources([], meetings: [:], question: "q", filter: .none, tokenBudget: 6_000), [])
    }
}
