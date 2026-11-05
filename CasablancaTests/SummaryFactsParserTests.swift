import XCTest
@testable import Casablanca

final class SummaryFactsParserTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return cal
    }

    /// Wednesday 2026-11-04, noon local time.
    private var meetingDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
    }

    private func decode(_ json: String) -> SummaryFacts? {
        try? SummaryFactsParser.decodeFacts(json, meetingDate: meetingDate, calendar: calendar).get()
    }

    private func item(_ task: String, owner: String? = nil, confidence: Double = 0.5,
                      due: String? = nil, quote: String? = nil, timestamp: String? = nil) -> ExtractedActionItem {
        ExtractedActionItem(task: task, owner: owner, due: due, dueIsExplicit: false, confidence: confidence,
                            quote: quote, timestamp: timestamp, verified: .unverified, verificationReason: nil)
    }

    // MARK: - Splitting

    func testSplitsTrailingJSONBlockFromMarkdown() {
        let response = "## Summary\nWe talked.\n\n## Action Items\n- **Kim** — Bel leverancier\n\n```json\n{\"topics\": [\"Planning\"]}\n```\n"
        let split = SummaryFactsParser.splitSinglePass(response)
        XCTAssertEqual(split.markdown, "## Summary\nWe talked.\n\n## Action Items\n- **Kim** — Bel leverancier")
        XCTAssertFalse(split.markdown.contains("```"))
        XCTAssertEqual(split.jsonText, "{\"topics\": [\"Planning\"]}")
    }

    func testSplitsSameLineJSONBlock() {
        let split = SummaryFactsParser.splitSinglePass("Notes\n```json{\"topics\":[]}```")
        XCTAssertEqual(split.markdown, "Notes")
        XCTAssertEqual(split.jsonText, "{\"topics\":[]}")
    }

    func testTakesTheLastJSONBlock() {
        let response = "Intro\n```json\n{\"topics\": [\"first\"]}\n```\nMiddle\n```swift\nlet x = 1\n```\n```\n{\"topics\": [\"last\"]}\n```"
        let split = SummaryFactsParser.splitSinglePass(response)
        XCTAssertEqual(split.jsonText, "{\"topics\": [\"last\"]}")
        XCTAssertTrue(split.markdown.contains("first"))
        XCTAssertTrue(split.markdown.contains("let x = 1"))
        XCTAssertFalse(split.markdown.contains("last"))
    }

    func testNoBlockLeavesMarkdownAndNilJSON() {
        let response = "\n## Summary\nNo JSON here.\n```swift\nlet x = 1\n```\n"
        let split = SummaryFactsParser.splitSinglePass(response)
        XCTAssertNil(split.jsonText)
        XCTAssertEqual(split.markdown, "## Summary\nNo JSON here.\n```swift\nlet x = 1\n```")
    }

    func testUnclosedTrailingJSONBlockIsTakenToTheEnd() {
        let split = SummaryFactsParser.splitSinglePass("Notes\n\n```json\n{\"topics\": [\"cut")
        XCTAssertEqual(split.markdown, "Notes")
        XCTAssertEqual(split.jsonText, "{\"topics\": [\"cut")
    }

    func testExtractsBareObjectFromProse() {
        XCTAssertEqual(SummaryFactsParser.extractJSONObject("Here: {\"topics\":[]} ok"), "{\"topics\":[]}")
        XCTAssertEqual(SummaryFactsParser.extractJSONObject("```json\n{\"a\": {\"b\": 1}}\n```"), "{\"a\": {\"b\": 1}}")
        XCTAssertNil(SummaryFactsParser.extractJSONObject("no object at all"))
        XCTAssertNil(SummaryFactsParser.extractJSONObject("} backwards {"))
    }

    // MARK: - Decoding

    func testDecodesFullObject() {
        let json = """
        {
          "topics": ["Planning", " "],
          "decisions": [{"text": "We kiezen leverancier B", "quote": "dan gaan we voor B", "timestamp": "[01:05]"}],
          "action_items": [
            {"task": "Stuur offerte", "owner": "Kim", "due": "2026-11-20", "due_is_explicit": true,
             "confidence": "high", "quote": "ik stuur de offerte", "timestamp": "[01:05]"},
            {"task": "Bel leverancier", "confidence": 0.7, "timestamp": "1:02:03"},
            {"task": "Plan demo", "confidence": "0,4", "timestamp": "later"},
            {"task": "   ", "owner": "Kim"},
            {"owner": "Kim"},
            "not an object"
          ],
          "open_questions": [{"text": "Is budget rond?", "timestamp": "02:00"}],
          "facts": [{"text": "Budget is 40k", "timestamp": null}]
        }
        """
        guard let facts = decode(json) else { return XCTFail("decode failed") }
        XCTAssertEqual(facts.topics, ["Planning"])
        XCTAssertEqual(facts.decisions, [ExtractedDecision(text: "We kiezen leverancier B", quote: "dan gaan we voor B", timestamp: "01:05")])
        XCTAssertEqual(facts.actionItems.count, 3)
        let first = facts.actionItems[0]
        XCTAssertEqual(first.task, "Stuur offerte")
        XCTAssertEqual(first.owner, "Kim")
        XCTAssertEqual(first.due, "2026-11-20")
        XCTAssertTrue(first.dueIsExplicit)
        XCTAssertEqual(first.confidence, 0.9)
        XCTAssertEqual(first.quote, "ik stuur de offerte")
        XCTAssertEqual(first.timestamp, "01:05")
        XCTAssertEqual(first.verified, .unverified)
        XCTAssertEqual(facts.actionItems[1].confidence, 0.7)
        XCTAssertEqual(facts.actionItems[1].timestamp, "1:02:03")
        XCTAssertFalse(facts.actionItems[1].dueIsExplicit)
        XCTAssertEqual(facts.actionItems[2].confidence, 0.4, accuracy: 0.0001)
        XCTAssertNil(facts.actionItems[2].timestamp)
        XCTAssertEqual(facts.openQuestions, [ExtractedNote(text: "Is budget rond?", timestamp: "02:00")])
        XCTAssertEqual(facts.facts, [ExtractedNote(text: "Budget is 40k", timestamp: nil)])
    }

    func testConfidenceDefaultsAndClamps() {
        let json = """
        {"action_items": [{"task": "a"}, {"task": "b", "confidence": 7}, {"task": "c", "confidence": "low"},
                          {"task": "d", "confidence": "medium"}, {"task": "e", "confidence": -1}, {"task": "f", "confidence": "vaag"}]}
        """
        XCTAssertEqual(decode(json)?.actionItems.map(\.confidence), [0.5, 1.0, 0.3, 0.6, 0.0, 0.5])
    }

    func testMissingKeysAreEmpty() {
        XCTAssertEqual(SummaryFactsParser.decodeFacts("{}", meetingDate: meetingDate, calendar: calendar), .success(.empty))
    }

    func testArrayTopLevelIsInvalid() {
        XCTAssertEqual(SummaryFactsParser.decodeFacts("[{\"topics\": []}]", meetingDate: meetingDate, calendar: calendar),
                       .failure(.invalidJSON))
        XCTAssertEqual(SummaryFactsParser.decodeFacts("{\"topics\": [", meetingDate: meetingDate, calendar: calendar),
                       .failure(.invalidJSON))
        XCTAssertEqual(SummaryFactsParser.decodeFacts("  ", meetingDate: meetingDate, calendar: calendar),
                       .failure(.noJSON))
    }

    func testGenericSpeakerLabelIsNeverAnOwner() {
        let owners = ["Spreker 2", "Speaker 1", "Anderen", "?", "speaker1", "Others", "me", "Ik", "I", "Unknown speaker", "**Sprecher 3**", "null"]
        let items = owners.map { "{\"task\": \"t\", \"owner\": \"\($0)\"}" }.joined(separator: ",")
        let json = "{\"action_items\": [\(items), {\"task\": \"t\", \"owner\": \" **Youri** \"}]}"
        guard let facts = decode(json) else { return XCTFail("decode failed") }
        XCTAssertEqual(facts.actionItems.map(\.owner), Array(repeating: nil, count: owners.count) + ["Youri"])
    }

    func testRelativeDueIsResolvedAgainstMeetingDate() {
        let json = "{\"action_items\": [{\"task\": \"t\", \"due\": \"vrijdag\", \"due_is_explicit\": false}, {\"task\": \"u\", \"due\": \"binnenkort\", \"due_is_explicit\": true}]}"
        guard let facts = decode(json) else { return XCTFail("decode failed") }
        XCTAssertEqual(facts.actionItems[0].due, "2026-11-06")
        XCTAssertTrue(facts.actionItems[0].dueIsExplicit)
        XCTAssertNil(facts.actionItems[1].due)
        XCTAssertFalse(facts.actionItems[1].dueIsExplicit)
    }

    // MARK: - Merging

    func testMergedCollapsesFuzzyDuplicateTasks() {
        let a = SummaryFacts(topics: ["Offerte"], decisions: [ExtractedDecision(text: "We gaan voor B")],
                             actionItems: [item("Stuur offerte naar Kim", confidence: 0.9, quote: "ik stuur hem")],
                             openQuestions: [], facts: [])
        let b = SummaryFacts(topics: ["offerte.", "Budget"],
                             decisions: [ExtractedDecision(text: "We gaan voor B.", quote: "voor B", timestamp: "03:00")],
                             actionItems: [item("Stuur de offerte naar Kim.", owner: "Youri", confidence: 0.6, due: "2026-11-06", quote: "anders"),
                                           item("Bel leverancier")],
                             openQuestions: [ExtractedNote(text: "q", timestamp: nil)], facts: [])
        let merged = SummaryFacts.merged([a, b])
        XCTAssertEqual(merged.topics, ["Offerte", "Budget"])
        XCTAssertEqual(merged.actionItems.count, 2)
        XCTAssertEqual(merged.actionItems[0].task, "Stuur offerte naar Kim")
        XCTAssertEqual(merged.actionItems[0].confidence, 0.9)
        XCTAssertEqual(merged.actionItems[0].owner, "Youri")
        XCTAssertEqual(merged.actionItems[0].due, "2026-11-06")
        XCTAssertEqual(merged.actionItems[0].quote, "ik stuur hem")
        XCTAssertEqual(merged.actionItems[1].task, "Bel leverancier")
        XCTAssertEqual(merged.decisions, [ExtractedDecision(text: "We gaan voor B", quote: "voor B", timestamp: "03:00")])
        XCTAssertEqual(merged.openQuestions.count, 1)
    }

    func testMergedPrefersHigherConfidenceFromLaterPart() {
        let a = SummaryFacts(topics: [], decisions: [], actionItems: [item("Plan demo", confidence: 0.3)], openQuestions: [], facts: [])
        let b = SummaryFacts(topics: [], decisions: [], actionItems: [item("Plan demo!", owner: "Kim", confidence: 0.8)], openQuestions: [], facts: [])
        let merged = SummaryFacts.merged([a, b])
        XCTAssertEqual(merged.actionItems, [item("Plan demo!", owner: "Kim", confidence: 0.8)])
    }

    // MARK: - Markdown fallback and rendering

    func testFromMarkdownUsesOwnerPrefix() {
        let parsed = SummaryResponseParser.ParsedResponse(
            summary: "", decisions: ["We gaan voor B"],
            todoTexts: ["**Kim** — Bel leverancier", "**Spreker 2** — Plan demo", "Losse taak"],
            risks: [], followUps: [], rawMarkdown: "")
        let facts = SummaryFacts.fromMarkdown(parsed)
        XCTAssertEqual(facts.actionItems, [item("Bel leverancier", owner: "Kim"), item("Plan demo"), item("Losse taak")])
        XCTAssertEqual(facts.decisions, [ExtractedDecision(text: "We gaan voor B")])
    }

    func testNotesMarkdownHeadingsAndTimestamps() {
        let facts = SummaryFacts(
            topics: ["Planning"],
            decisions: [ExtractedDecision(text: "We gaan voor B", timestamp: "01:05")],
            actionItems: [item("Stuur offerte", owner: "Kim", due: "2026-11-06", timestamp: "02:10"), item("Bel leverancier")],
            openQuestions: [],
            facts: [ExtractedNote(text: "Budget is 40k", timestamp: "1:00:00")])
        XCTAssertEqual(facts.notesMarkdown(), """
        ### Topics discussed
        - Planning
        ### Decisions
        - [01:05] We gaan voor B
        ### Action items (owner: what)
        - [02:10] Kim: Stuur offerte (2026-11-06)
        - ?: Bel leverancier
        ### Notable statements and figures
        - [1:00:00] Budget is 40k
        """)
        XCTAssertEqual(SummaryFacts.empty.notesMarkdown(), "")
    }

    // MARK: - Prompt copy

    func testPromptsCarryMeetingDateAndShape() {
        let instruction = SummaryFactsPrompt.singlePassInstruction(meetingDate: meetingDate, calendar: calendar)
        XCTAssertTrue(instruction.hasPrefix("After the notes, add one fenced code block that starts with ```json"))
        XCTAssertTrue(instruction.contains(SummaryFactsPrompt.objectShape))
        XCTAssertTrue(instruction.contains("The meeting took place on 2026-11-04 (Wednesday)."))
        XCTAssertTrue(instruction.hasSuffix("\n- Every action item and decision in the notes appears in the JSON, and nothing else does."))
        XCTAssertTrue(SummaryFactsPrompt.repairPrompt(broken: "{oops").hasSuffix("\n\nText:\n{oops"))
        let rebuild = SummaryFactsPrompt.rebuildPrompt(fromMarkdown: "## Decisions\n- B", meetingDate: meetingDate, calendar: calendar)
        XCTAssertTrue(rebuild.hasPrefix("These are the closing sections of meeting notes."))
        XCTAssertTrue(rebuild.contains(SummaryFactsPrompt.rules(meetingDate: meetingDate, calendar: calendar)))
        XCTAssertTrue(rebuild.hasSuffix("\n\nNotes:\n## Decisions\n- B"))
    }
}
