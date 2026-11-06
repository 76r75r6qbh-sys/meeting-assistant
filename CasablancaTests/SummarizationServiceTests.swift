import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class SummarizationServiceTests: XCTestCase {
    func testDefaultPromptTemplateIncludesTranscriptAndUserFocus() {
        let template = SummarizationService.defaultPromptTemplate

        XCTAssertTrue(template.contains("Transcript:"))
        XCTAssertTrue(template.contains("{{transcript}}"))
        XCTAssertTrue(template.contains("{{user_focus}}"))
        XCTAssertFalse(template.contains("{{freeform_notes}}"), "user notes travel in the focus block now")
        XCTAssertFalse(template.contains("Freeform notes:"))
    }

    // MARK: - Pocket-style template placeholders

    func testDefaultPromptTemplateContainsParticipantsPlaceholder() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("{{participants}}"), "Template must include {{participants}} placeholder")
    }

    func testDefaultPromptTemplateContainsTerminologyListPlaceholder() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("{{terminology_list}}"), "Template must include {{terminology_list}} placeholder")
    }

    func testDefaultPromptTemplateContainsDutchClosingHeadings() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("Besluiten"), "Template must reference Dutch heading 'Besluiten'")
        XCTAssertTrue(template.contains("Actiepunten"), "Template must reference Dutch heading 'Actiepunten'")
        XCTAssertTrue(template.contains("Risico"), "Template must reference Dutch heading 'Risico's en blockers'")
        XCTAssertTrue(template.contains("Opvolging"), "Template must reference Dutch heading 'Opvolging'")
    }

    func testDefaultPromptTemplateContainsEnglishClosingHeadings() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("Decisions"), "Template must reference English heading 'Decisions'")
        XCTAssertTrue(template.contains("Action Items"), "Template must reference English heading 'Action Items'")
        XCTAssertTrue(template.contains("Risks and Blockers"), "Template must reference English heading 'Risks and Blockers'")
        XCTAssertTrue(template.contains("Follow-ups"), "Template must reference English heading 'Follow-ups'")
    }

    // MARK: - renderPrompt participants injection

    func testRenderPromptSubstitutesParticipantsWhenPresent() {
        let meeting = Meeting(
            title: "Sprint Review",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            participants: ["Alice", "Bob", "Carol"]
        )
        let rendered = SummarizationService.renderPrompt(
            template: "Participants: {{participants}}",
            meeting: meeting,
            transcript: "",
            freeformNotes: "",
            terminologyBlock: ""
        )
        XCTAssertTrue(rendered.contains("Alice, Bob, Carol"), "renderPrompt must join participants with ', '")
        XCTAssertFalse(rendered.contains("{{participants}}"), "renderPrompt must replace {{participants}} placeholder")
    }

    func testRenderPromptSubstitutesUnknownWhenParticipantsEmpty() {
        let meeting = Meeting(
            title: "Quick Sync",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            participants: []
        )
        let rendered = SummarizationService.renderPrompt(
            template: "Participants: {{participants}}",
            meeting: meeting,
            transcript: "",
            freeformNotes: "",
            terminologyBlock: ""
        )
        XCTAssertTrue(rendered.contains("Unknown"), "renderPrompt must use 'Unknown' when participants list is empty")
        XCTAssertFalse(rendered.contains("{{participants}}"), "renderPrompt must replace {{participants}} placeholder")
    }

    func testRenderPromptSubstitutesTranscriptAndFocusBlock() {
        let meeting = Meeting(title: "Design Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        let focus = SummaryPromptContext.focusBlock(prep: nil, notes: "Freeform notes body", maxTokens: 400)
        let rendered = SummarizationService.renderPrompt(
            template: SummarizationService.defaultPromptTemplate,
            meeting: meeting,
            transcript: "Transcript body",
            freeformNotes: "Freeform notes body",
            terminologyBlock: "",
            focusBlock: focus
        )

        XCTAssertTrue(rendered.contains("Transcript:\nTranscript body"))
        XCTAssertTrue(rendered.contains("\n\n" + focus + "\n\nTranscript:\n"))
        XCTAssertTrue(rendered.contains("User notes:\nFreeform notes body"))
        XCTAssertFalse(rendered.contains("{{user_focus}}"))
    }

    func testRenderPromptDropsThePlaceholderLineAndOneBlankLineWhenThereIsNoFocus() {
        let meeting = Meeting(title: "Design Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: "Participants: {{participants}}\n\n{{user_focus}}\n\nTranscript:\n{{transcript}}",
            meeting: meeting,
            transcript: "Body",
            freeformNotes: "",
            terminologyBlock: ""
        )
        XCTAssertEqual(rendered, "Participants: Unknown\n\nTranscript:\nBody")
    }

    func testRenderPromptInsertsTheFocusAboveATranscriptHeadingInACustomTemplate() {
        let meeting = Meeting(title: "Design Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: "INTRO\n  Transcript:  \n{{transcript}}",
            meeting: meeting,
            transcript: "Body",
            freeformNotes: "",
            terminologyBlock: "",
            focusBlock: "FOCUS"
        )
        XCTAssertEqual(rendered, "INTRO\nFOCUS\n\n  Transcript:  \nBody")
    }

    func testRenderPromptUsesTheGivenParticipantsLine() {
        let meeting = Meeting(title: "Sync", date: .now, participants: ["Kim"])
        let rendered = SummarizationService.renderPrompt(
            template: "Participants: {{participants}}",
            meeting: meeting,
            transcript: "",
            freeformNotes: "",
            terminologyBlock: "",
            participantsLine: "Kim, Youri (me)"
        )
        XCTAssertEqual(rendered, "Participants: Kim, Youri (me)")
    }

    func testStripReasoningRemovesThinkTags() {
        let raw = "<think>Let me reason about this...</think>\n# Summary\nAll good."
        let cleaned = SummarizationService.stripReasoning(raw)
        XCTAssertEqual(cleaned, "# Summary\nAll good.")
    }

    func testStripReasoningDropsUntaggedPreambleBeforeFirstHeading() {
        let raw = """
        Thinking Process:
        1. Analyze the request.
        2. Draft the sections.
        Wait, let me reconsider the time.

        # Summary
        The team aligned on the plan.

        ## Decisions
        - Ship Friday
        """
        let cleaned = SummarizationService.stripReasoning(raw)
        XCTAssertTrue(cleaned.hasPrefix("# Summary"))
        XCTAssertFalse(cleaned.contains("Thinking Process"))
        XCTAssertTrue(cleaned.contains("## Decisions"))
    }

    func testStripReasoningLeavesCleanOutputUnchanged() {
        let raw = "# Summary\nDone.\n## Action Items\n- Send notes"
        XCTAssertEqual(SummarizationService.stripReasoning(raw), raw)
    }

    // MARK: - Generation timeout

    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .completed)
        meeting.transcript = "Alice: We ship Friday. Bob: Agreed."
        return meeting
    }

    /// The 120s at this call site was chosen for a local model. A provider that pays
    /// a network round trip per call states its own budget, and it has to arrive —
    /// this generation is wrapped in `LLMRetryPolicy`, so a timeout that fires costs
    /// three billed generations instead of one slow success.
    func testSummarizeUsesTheProvidersPreferredTimeoutWhenItHasOne() async throws {
        let stub = StubLLMProvider(preferredTimeout: 300, outcomes: [.success(SummaryFixtures.withFacts("# Summary\nWe ship Friday."))])
        let service = makeService(stub)

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.timeout, 300)
    }

    /// A local provider keeps the call site's own number, so nothing changes for it.
    func testSummarizeKeepsItsOwnTimeoutForAProviderWithoutAPreference() async throws {
        let stub = StubLLMProvider(preferredTimeout: nil, outcomes: [.success(SummaryFixtures.withFacts("# Summary\nWe ship Friday."))])
        let service = makeService(stub)

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(stub.calls.first?.timeout, 120)
    }

    // MARK: - Provider budget and injected settings

    /// A throwaway defaults suite (removed on teardown), so no test reads or
    /// writes the user's domain.
    private func makeDefaults() -> UserDefaults {
        makeScratchDefaults(label: "SummarizationServiceTests")
    }

    /// ~147,000 chars of `[mm:ss]` lines: the 2.5-hour meeting that lost ~84 % of
    /// its content to the old fixed 6,000-token budget.
    private func makeLongTranscript(chars: Int = 147_000) -> String {
        var lines: [String] = []
        var total = 0
        var i = 0
        while total < chars {
            let line = String(format: "[%d:%02d:%02d] Spreker %d: punt %05d over de planning en het budget.",
                              i / 3600, (i / 60) % 60, i % 60, i % 4, i)
            lines.append(line)
            total += line.count + 1
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    /// The one-pass cap applies to every provider: a 100k-budget provider
    /// still gets parts of at most `onePassTokenCap`, then one reduce.
    func testALongTranscriptOverTheOnePassCapIsChunkedOnALargeBudgetProvider() async throws {
        let transcript = makeLongTranscript()
        XCTAssertGreaterThanOrEqual(transcript.count, 147_000)
        let meeting = Meeting(title: "EHDS", date: .now, status: .completed)
        meeting.transcript = transcript
        let stub = StubLLMProvider(promptTokenBudget: 100_000, outcomes: numberedNotes())
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeDefaults())

        _ = try await service.summarize(meeting: meeting)

        let mapCalls = stub.calls.filter(isMapCall)
        XCTAssertGreaterThanOrEqual(mapCalls.count, 2)
        for call in mapCalls {
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(call.prompt), SummarizationService.onePassTokenCap)
            XCTAssertEqual(call.maxTokens, 2_500, "12,500-token parts get a fifth of their size as output")
        }
        let last = try XCTUnwrap(stub.calls.last)
        XCTAssertFalse(isMapCall(last))
        XCTAssertTrue(last.prompt.contains(SummarizationService.condensedNotesPreamble), "the last call is the reduce")
        XCTAssertEqual(stub.calls.count, mapCalls.count + 1)
        XCTAssertNil(service.warningMessage)
    }

    /// Template, terminology and thinking flag come from the injected suite, not
    /// `UserDefaults.standard`.
    func testSummarizeReadsItsSettingsFromTheInjectedDefaults() async throws {
        let defaults = makeDefaults()
        defaults.set("CUSTOM TEMPLATE {{terminology_list}} :: {{transcript}}", forKey: AppPreferenceKey.summaryPromptTemplate)
        defaults.set(true, forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        defaults.set("Medicore", forKey: AppPreferenceKey.terminologyList)
        defaults.set(true, forKey: AppPreferenceKey.summaryThinkingEnabled)
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: defaults)

        _ = try await service.summarize(meeting: makeMeeting())

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.prompt.hasPrefix("CUSTOM TEMPLATE"))
        XCTAssertTrue(call.prompt.contains("Medicore"))
        XCTAssertTrue(call.prompt.contains("We ship Friday."))
        // Thinking on → uncapped output and no `/no_think` switch.
        XCTAssertNil(call.maxTokens)
        XCTAssertFalse(call.prompt.contains(LLMPromptSupport.noThinkSuffix))
    }

    func testSummarizeUsesTheInjectedRetryPolicy() async throws {
        let stub = StubLLMProvider(
            outcomes: [.failure(StubLLMProvider.transientFailure()), .success(SummaryFixtures.withFacts("# Summary\nDone."))]
        )
        let service = SummarizationService(
            providerFactory: { stub },
            userDefaults: makeDefaults(),
            // No real backoff: a sleeping policy would make this test take seconds.
            retryPolicy: LLMRetryPolicy(maxAttempts: 2, baseDelay: 0, sleep: { _ in })
        )

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(stub.calls.count, 2)
    }

    /// The stub's per-outcome truncated flag reaches the existing output-limit warning.
    func testSummarizeWarnsWhenTheProviderReportsTruncatedOutput() async throws {
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))], truncatedFlags: [true])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeDefaults())

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(service.warningMessage, "Summary may be truncated: Stub reached its output length limit.")
    }

    // MARK: - Map-reduce

    /// A budget small enough that a ~20k-char transcript needs several parts,
    /// yet big enough that a minimum (1,000-token) part fits next to the JSON
    /// map prompt's ~700 tokens of instructions.
    private let smallBudget = 2_000

    /// Defaults with a short fixed template and a pinned note-taker, so prompt
    /// sizes in these tests don't depend on the default template or the Mac's
    /// user name. `padding` grows the template's fixed overhead.
    private func makeMapReduceDefaults(padding: Int = 0, thinking: Bool = false) -> UserDefaults {
        let defaults = makeDefaults()
        defaults.set(
            "TEMPLATE \(String(repeating: "x", count: padding))\n{{transcript}}\nNOTES {{freeform_notes}}",
            forKey: AppPreferenceKey.summaryPromptTemplate
        )
        defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)
        defaults.set(thinking, forKey: AppPreferenceKey.summaryThinkingEnabled)
        return defaults
    }

    private func makeMeeting(transcript: String) -> Meeting {
        let meeting = Meeting(title: "EHDS", date: .now, status: .completed)
        meeting.transcript = transcript
        return meeting
    }

    /// Canned per-call facts `{"topics":["NOTE-01"]}`, … (zero-padded so no note
    /// is a prefix of another).
    private func numberedNotes(_ count: Int = 60) -> [Result<String, Error>] {
        (1...count).map { .success(note($0)) }
    }

    /// Part `n`'s canned facts: one topic `NOTE-nn`.
    private func note(_ n: Int) -> String {
        SummaryFixtures.partJSON(topic: String(format: "NOTE-%02d", n))
    }

    private func isMapCall(_ call: StubLLMProvider.Call) -> Bool {
        call.prompt.hasPrefix("You are extracting facts from part")
    }

    private func isRepairCall(_ call: StubLLMProvider.Call) -> Bool {
        call.prompt.hasPrefix("The text below was meant to be one JSON object")
    }

    private func isMergeCall(_ call: StubLLMProvider.Call) -> Bool {
        call.prompt.hasPrefix("You are merging")
    }

    func testShortTranscriptOnASmallBudgetIsOneCallWithTheWholeTranscript() async throws {
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertTrue(try XCTUnwrap(stub.calls.first?.prompt).contains("Alice: We ship Friday. Bob: Agreed."))
        XCTAssertNil(service.warningMessage)
    }

    func testLongTranscriptOnASmallBudgetIsCondensedInPartsThenReducedWithTheTemplate() async throws {
        let transcript = makeLongTranscript(chars: 20_000)
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting(transcript: transcript))

        let mapCalls = stub.calls.filter(isMapCall)
        let partCount = mapCalls.count
        XCTAssertGreaterThan(partCount, 3)
        XCTAssertEqual(stub.calls.count, partCount + 1, "N map calls, then exactly one reduce")
        for (i, call) in mapCalls.enumerated() {
            XCTAssertTrue(call.prompt.hasPrefix("You are extracting facts from part \(i + 1) of \(partCount) of a meeting transcript"))
            XCTAssertTrue(call.prompt.contains("Meeting: EHDS. Participants: Unknown. The note-taker is Youri."))
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(call.prompt), smallBudget, "a part must fit the budget")
            XCTAssertEqual(call.maxTokens, 1_500, "JSON parts get their own cap, never below 1,500")
            XCTAssertTrue(call.prompt.hasSuffix(LLMPromptSupport.noThinkSuffix))
        }
        XCTAssertTrue(mapCalls[0].prompt.contains("(0:00:00–"), "the first part is labelled from its first timestamp")
        // Terminology off: the meeting line runs straight into the instructions,
        // with no blank line where the empty terminology block would have gone.
        let headerLines = mapCalls[0].prompt.components(separatedBy: "\n").prefix(4)
        XCTAssertEqual(headerLines.count, 4)
        XCTAssertTrue(headerLines[0].hasPrefix("You are extracting facts from part 1 of \(partCount) of a meeting transcript"))
        XCTAssertTrue(headerLines[1].hasPrefix("(0:00:00–") && headerLines[1].hasSuffix(") so it can be summarized later."))
        XCTAssertEqual(headerLines[2], "Meeting: EHDS. Participants: Unknown. The note-taker is Youri.")
        XCTAssertEqual(headerLines[3], "Return only one JSON object, no prose and no code fence, with exactly this shape:")

        let reduce = try XCTUnwrap(stub.calls.last).prompt
        XCTAssertTrue(reduce.hasPrefix("TEMPLATE"), "the reduce runs through the user's template")
        XCTAssertTrue(reduce.contains(SummarizationService.condensedNotesPreamble))
        XCTAssertFalse(reduce.contains(transcript))
        XCTAssertFalse(reduce.contains("punt 00100 over de planning"), "no raw transcript line reaches the reduce")
        var searchFrom = reduce.startIndex
        for part in 1...partCount {
            let heading = try XCTUnwrap(
                reduce.range(of: "## Part \(part)/\(partCount) (", range: searchFrom..<reduce.endIndex),
                "part \(part) heading in order"
            )
            let note = try XCTUnwrap(
                reduce.range(of: String(format: "NOTE-%02d", part), range: heading.upperBound..<reduce.endIndex),
                "part \(part) notes in order"
            )
            searchFrom = note.upperBound
        }
        XCTAssertNil(service.warningMessage, "map-reduce without fallback is not a warning")
    }

    func testCondensedNotesThatStillDoNotFitAreMergedOneLevel() async throws {
        // Template overhead > merge-prompt overhead: several notes merge into one
        // call's input, but not into the summary prompt.
        let note = SummaryFixtures.bulkyPartJSON(chars: 600)
        let recorder = PhaseRecorder()
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success(note)],
            onGenerate: { recorder.record() }
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults(padding: 1_800))
        recorder.service = service

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 40_000)))

        let mergeCalls = stub.calls.filter(isMergeCall)
        XCTAssertFalse(mergeCalls.isEmpty, "the notes overflowed, so a merge level ran")
        XCTAssertTrue(recorder.phases.contains(.merging(level: 1)))
        XCTAssertFalse(recorder.phases.contains(.merging(level: 2)), "one level was enough")
        for call in mergeCalls {
            XCTAssertTrue(call.prompt.contains("Merge these chronological partial meeting notes into one set of notes with the same headings; deduplicate; keep timestamps and owners."))
            XCTAssertTrue(call.prompt.contains("## Part "), "merge input keeps the part headings")
            XCTAssertEqual(call.maxTokens, LLMPromptSupport.mapOutputTokens)
        }
        XCTAssertFalse(try XCTUnwrap(stub.calls.last).prompt.contains("transcript truncated"))
        XCTAssertNil(service.warningMessage)
    }

    func testMergingStopsAfterThreeLevelsThenElidesWithTheShortenedWarning() async throws {
        // Two notes fit one merge call but never the summary prompt, so every level
        // halves the count without ever fitting.
        let note = SummaryFixtures.bulkyPartJSON(chars: 2_400)
        let recorder = PhaseRecorder()
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success(note)],
            onGenerate: { recorder.record() }
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults(padding: 1_800))
        recorder.service = service

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 45_000)))

        let levels = recorder.phases.compactMap { phase -> Int? in
            if case .merging(let level) = phase { return level }
            return nil
        }
        XCTAssertEqual(levels.max(), LLMPromptSupport.maxMergeLevels)
        XCTAssertEqual(Set(levels), [1, 2, 3])
        let reduce = try XCTUnwrap(stub.calls.last).prompt
        XCTAssertTrue(reduce.contains("transcript truncated"), "the joined notes were middle-elided")
        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(reduce), smallBudget)
        XCTAssertEqual(service.warningMessage, "The meeting was too long to summarize fully; some middle sections were shortened.")
    }

    func testMergeGroupsPassAnOversizedNoteThroughAlone() {
        let small = SummarizationService.CondensedNote(text: String(repeating: "a", count: 300), startLabel: nil, endLabel: nil)
        let big = SummarizationService.CondensedNote(text: String(repeating: "b", count: 3_000), startLabel: nil, endLabel: nil)

        let groups = SummarizationService.mergeGroups([small, small, big, small], capacityTokens: 500)

        XCTAssertEqual(groups, [0..<2, 2..<3, 3..<4])
    }

    func testThinkingOnLeavesMapCallsUncapped() async throws {
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults(thinking: true))

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 20_000)))

        let mapCalls = stub.calls.filter(isMapCall)
        XCTAssertFalse(mapCalls.isEmpty)
        for call in mapCalls {
            XCTAssertNil(call.maxTokens, "reasoning would eat a 900-token cap and the notes would vanish")
            XCTAssertFalse(call.prompt.contains(LLMPromptSupport.noThinkSuffix))
        }
    }

    func testAPartThatIsOnlyReasoningIsAnEmptyResponseError() async throws {
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success(note(1)), .success("<think>Nothing to note.</think>"), .success(note(3))]
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        do {
            _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 20_000)))
            XCTFail("an empty part must fail the summary, not be skipped")
        } catch SummarizationError.emptyResponse(let provider) {
            XCTAssertEqual(provider, "Stub")
        }
        XCTAssertEqual(stub.calls.count, 2, "nothing runs after the empty part")
    }

    func testMapPromptKeepsTheTerminologyBlockOnItsOwnLines() async throws {
        let defaults = makeMapReduceDefaults()
        defaults.set(true, forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        defaults.set("Medicore", forKey: AppPreferenceKey.terminologyList)
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        let service = SummarizationService(providerFactory: { stub }, userDefaults: defaults)

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 20_000)))

        let block = TerminologyService.renderTerminologyBlock(enabled: true, raw: "Medicore")
        let prompt = try XCTUnwrap(stub.calls.first(where: isMapCall)).prompt
        XCTAssertTrue(prompt.contains(
            "The note-taker is Youri.\n\(block)\nReturn only one JSON object, no prose and no code fence"
        ))
    }

    /// Part counts for a 20k transcript on `smallBudget`, so a test can place a
    /// truncated flag on the final call.
    private func mapCallCount(for transcript: String) async throws -> Int {
        let probe = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        let service = SummarizationService(providerFactory: { probe }, userDefaults: makeMapReduceDefaults())
        _ = try await service.summarize(meeting: makeMeeting(transcript: transcript))
        return probe.calls.filter(isMapCall).count
    }

    func testTruncatedPartNotesSetTheNotesOutputLimitWarning() async throws {
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes(), truncatedFlags: [true, false])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 20_000)))

        XCTAssertEqual(
            service.warningMessage,
            "Notes for some parts hit the output limit; the summary may miss details from them."
        )
    }

    func testATruncatedFinalCallAfterMapReduceKeepsTheSummaryWarning() async throws {
        let transcript = makeLongTranscript(chars: 20_000)
        let parts = try await mapCallCount(for: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: numberedNotes(),
            truncatedFlags: Array(repeating: false, count: parts) + [true]
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting(transcript: transcript))

        XCTAssertEqual(stub.calls.count, parts + 1)
        XCTAssertEqual(service.warningMessage, "Summary may be truncated: Stub reached its output length limit.")
    }

    func testTruncatedNotesAndATruncatedSummaryShowBothWarnings() async throws {
        let transcript = makeLongTranscript(chars: 20_000)
        let parts = try await mapCallCount(for: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: numberedNotes(),
            truncatedFlags: [true] + Array(repeating: false, count: parts - 1) + [true]
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting(transcript: transcript))

        XCTAssertEqual(
            service.warningMessage,
            "Notes for some parts hit the output limit; the summary may miss details from them. Summary may be truncated: Stub reached its output length limit."
        )
    }

    /// Template + notes alone exceed the budget: merging can never make the notes
    /// fit, so no merge call is spent and the fallback runs at once.
    func testNoMergeCallsWhenTheTemplateAloneFillsTheBudget() async throws {
        let recorder = PhaseRecorder()
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: numberedNotes(),
            onGenerate: { recorder.record() }
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults(padding: 6_000))
        recorder.service = service

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 20_000)))

        let mapCount = stub.calls.filter(isMapCall).count
        XCTAssertGreaterThan(mapCount, 1)
        XCTAssertTrue(stub.calls.filter(isMergeCall).isEmpty, "a merge cannot help when the template fills the budget")
        XCTAssertFalse(recorder.phases.contains { if case .merging = $0 { return true } else { return false } })
        XCTAssertEqual(stub.calls.count, mapCount + 1, "map calls, then the final call")
        XCTAssertEqual(service.warningMessage, SummarizationService.shortenedWarning)
    }

    /// Two notes that are each too big to share a merge call: the level would
    /// regroup them one per group, so it is skipped and the fallback runs.
    func testAMergeLevelThatCannotReduceTheNoteCountBreaksOut() async throws {
        let bigNote = SummaryFixtures.bulkyPartJSON(chars: 3_600)
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: [.success(bigNote)])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 5_000)))

        XCTAssertEqual(stub.calls.filter(isMapCall).count, 2, "two parts, so two oversized notes")
        XCTAssertTrue(stub.calls.filter(isMergeCall).isEmpty, "no merge call that would only repeat itself")
        XCTAssertEqual(stub.calls.count, 3)
        let reduce = try XCTUnwrap(stub.calls.last).prompt
        XCTAssertTrue(reduce.contains("transcript truncated"), "the joined notes were middle-elided")
        XCTAssertEqual(service.warningMessage, SummarizationService.shortenedWarning)
    }

    /// Cancelling between parts stops the run: no further provider calls, and the
    /// background path shows no error for it.
    func testCancellationBetweenPartsStopsFurtherCallsAndSurfacesNoError() async throws {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let meeting = makeMeeting(transcript: makeLongTranscript(chars: 20_000))
        context.insert(meeting)

        let holder = ServiceHolder()
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: numberedNotes(),
            onGenerate: { holder.service?.cancelBackgroundWork() }
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())
        holder.service = service

        service.summarizeInBackground(meeting: meeting, modelContext: context)
        let deadline = Date().addingTimeInterval(5)
        while service.isSummarizing, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(service.isSummarizing)
        XCTAssertEqual(stub.calls.count, 1, "part 2 is never requested after the cancel")
        XCTAssertTrue(isMapCall(try XCTUnwrap(stub.calls.first)))
        XCTAssertNil(service.errorMessage, "cancellation is not a failure")
        XCTAssertNil(meeting.summary)
    }

    func testAFailedPartFailsTheSummaryAndRetryReusesTheCondensedParts() async throws {
        let transcript = makeLongTranscript(chars: 20_000)
        let meeting = makeMeeting(transcript: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [
                .success(note(1)), .success(note(2)),
                .failure(StubLLMProvider.transientFailure()), .failure(StubLLMProvider.transientFailure()),
                .success(SummaryFixtures.partJSON(topic: "NOTE-LATER"))
            ]
        )
        let service = SummarizationService(
            providerFactory: { stub },
            userDefaults: makeMapReduceDefaults(),
            retryPolicy: LLMRetryPolicy(maxAttempts: 2, baseDelay: 0, sleep: { _ in })
        )

        do {
            _ = try await service.summarize(meeting: meeting)
            XCTFail("part 3 failed on every attempt")
        } catch SummarizationError.requestFailed(let message) {
            XCTAssertEqual(message, "stub timeout")
        }
        XCTAssertEqual(stub.calls.count, 4, "parts 1-2, then part 3 twice")

        // Retry: parts 1 and 2 come from the cache.
        _ = try await service.summarize(meeting: meeting)
        let retryCalls = stub.calls.dropFirst(4)
        XCTAssertTrue(try XCTUnwrap(retryCalls.first).prompt.hasPrefix("You are extracting facts from part 3 of"))
        XCTAssertFalse(retryCalls.contains { $0.prompt.hasPrefix("You are extracting facts from part 1 of") || $0.prompt.hasPrefix("You are extracting facts from part 2 of") })
        let reduce = try XCTUnwrap(retryCalls.last).prompt
        XCTAssertTrue(reduce.contains("NOTE-01") && reduce.contains("NOTE-02"), "cached parts reach the reduce")

        // Success cleared the meeting's parts: summarizing again condenses afresh.
        let before = stub.calls.count
        _ = try await service.summarize(meeting: meeting)
        XCTAssertTrue(stub.calls[before].prompt.hasPrefix("You are extracting facts from part 1 of"))
    }

    func testTheCacheIsReplacedWhenAnotherMeetingIsSummarized() async throws {
        let transcript = makeLongTranscript(chars: 20_000)
        let first = makeMeeting(transcript: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success(note(1)), .failure(LLMProviderError.requestFailed(provider: "Stub", kind: .httpStatus(400), message: "bad")), .success(SummaryFixtures.partJSON(topic: "NOTE"))]
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try? await service.summarize(meeting: first)
        XCTAssertEqual(stub.calls.count, 2)

        _ = try await service.summarize(meeting: makeMeeting(transcript: transcript))
        let before = stub.calls.count
        _ = try await service.summarize(meeting: first)
        XCTAssertTrue(stub.calls[before].prompt.hasPrefix("You are extracting facts from part 1 of"), "the first meeting's parts were dropped")
    }

    func testPhasesProgressThroughEachPartThenSending() async throws {
        let recorder = PhaseRecorder()
        let stub = StubLLMProvider(
            displayName: "Ollama",
            promptTokenBudget: smallBudget,
            outcomes: [.success(note(1)), .failure(StubLLMProvider.transientFailure())] + numberedNotes(),
            onGenerate: { recorder.record() }
        )
        let service = SummarizationService(
            providerFactory: { stub },
            userDefaults: makeMapReduceDefaults(),
            retryPolicy: LLMRetryPolicy(maxAttempts: 3, baseDelay: 0, sleep: { _ in })
        )
        recorder.service = service

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 20_000)))

        // Distinct prompts: part 2's retry repeats its prompt.
        let partCount = Set(stub.calls.filter(isMapCall).map(\.prompt)).count
        // Part 2's first attempt fails; its retry shows `.retrying`, and part 3
        // announces itself again rather than leaving "retrying" up.
        var expected: [SummarizationService.SummarizationPhase] = [
            .condensing(part: 1, of: partCount),
            .condensing(part: 2, of: partCount),
            .retrying(attempt: 2, maxAttempts: 3)
        ]
        expected += (3...partCount).map { .condensing(part: $0, of: partCount) }
        expected.append(.sending)
        XCTAssertEqual(recorder.phases, expected)
        XCTAssertEqual(recorder.statuses.first, "Summarizing part 1 of \(partCount) with Ollama…")
        XCTAssertEqual(SummarizationService.mergingStatus(level: 2), "Combining notes (step 2)…")
    }

    // MARK: - Map step facts (JSON per part, merged action items)

    /// `[h:mm:ss] Spreker n: …` lines, or the same without the speaker label.
    private func makeMapTranscript(chars: Int = 20_000, speakers: Bool) -> String {
        guard !speakers else { return makeLongTranscript(chars: chars) }
        return makeLongTranscript(chars: chars)
            .replacingOccurrences(of: #"\] Spreker \d+: "#, with: "] ", options: .regularExpression)
    }

    func testMapPromptAsksForJSONAndKeepsTheHeaderLines() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
            let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

            _ = try await service.summarize(meeting: makeMeeting(transcript: makeMapTranscript(speakers: speakers)))

            let mapCalls = stub.calls.filter(isMapCall)
            XCTAssertGreaterThan(mapCalls.count, 1)
            let lines = mapCalls[0].prompt.components(separatedBy: "\n")
            XCTAssertTrue(lines[0].hasPrefix("You are extracting facts from part 1 of \(mapCalls.count) of a meeting transcript"))
            XCTAssertTrue(lines[1].hasPrefix("(0:00:00–") && lines[1].hasSuffix(") so it can be summarized later."))
            XCTAssertEqual(lines[2], "Meeting: EHDS. Participants: Unknown. The note-taker is Youri.")
            XCTAssertEqual(lines[3], "Return only one JSON object, no prose and no code fence, with exactly this shape:")
            let prompt = mapCalls[0].prompt
            XCTAssertTrue(prompt.contains(SummaryFactsPrompt.objectShape))
            XCTAssertTrue(prompt.contains("Rules for the JSON:"))
            XCTAssertTrue(prompt.contains("Only use this part of the transcript.\n\nTranscript part:\n"))
            let reduce = try XCTUnwrap(stub.calls.last).prompt
            XCTAssertFalse(reduce.contains("```json"), "the reduce gets no JSON instruction")
        }
    }

    func testMapPromptCarriesTheTrimmedFocus() async throws {
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        let service = makeService(stub, defaults: makeMapReduceDefaults(), prep: "Vraag naar budget")

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeMapTranscript(speakers: true)))

        let map = try XCTUnwrap(stub.calls.first(where: isMapCall)).prompt
        XCTAssertTrue(map.contains(
            "The note-taker is Youri.\n\(SummaryPromptContext.focusHeader)\nPrep:\nVraag naar budget\nReturn only one JSON object"
        ))
    }

    func testReduceGetsDeduplicatedActionItemsFromTheParts() async throws {
        for speakers in [true, false] {
            let part = SummaryFixtures.partJSON(topic: "Offerte", actionItems: [("Stuur offerte", "Kim")])
            let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: [.success(part)])
            let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

            let outcome = try await service.summarizeWithFacts(
                meeting: makeMeeting(transcript: makeMapTranscript(speakers: speakers))
            )

            XCTAssertGreaterThanOrEqual(stub.calls.filter(isMapCall).count, 2)
            let reduce = try XCTUnwrap(stub.calls.last).prompt
            XCTAssertTrue(reduce.contains(SummarizationService.reducedActionItemsHeading))
            XCTAssertEqual(occurrences(of: "**Kim** — Stuur offerte", in: reduce), 1)
            XCTAssertEqual(outcome.factsSource, .mapJSON)
            XCTAssertEqual(outcome.facts.actionItems.count, 1)
            XCTAssertEqual(outcome.facts.actionItems.first?.owner, "Kim")
            XCTAssertNil(service.warningMessage)
        }
    }

    func testAnUnownedPartItemIsListedWithAQuestionMark() async throws {
        let part = SummaryFixtures.partJSON(topic: "Demo", actionItems: [("Plan de demo", nil)])
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: [.success(part)])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeMapTranscript(speakers: true)))

        let reduce = try XCTUnwrap(stub.calls.last).prompt
        XCTAssertTrue(reduce.contains(SummarizationService.reducedActionItemsHeading + "\n- **?** — Plan de demo\nNOTES None"))
    }

    func testAPartWithBrokenJSONIsRepairedOnce() async throws {
        for speakers in [true, false] {
            let transcript = makeMapTranscript(speakers: speakers)
            let parts = try await mapCallCount(for: transcript)
            XCTAssertGreaterThan(parts, 2)
            let stub = StubLLMProvider(
                promptTokenBudget: smallBudget,
                outcomes: [.success(note(1)), .success("{bad"), .success(note(2))] + (3...parts + 1).map { .success(note($0)) }
            )
            let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

            let outcome = try await service.summarizeWithFacts(meeting: makeMeeting(transcript: transcript))

            XCTAssertEqual(stub.calls.count, parts + 2, "N map calls, one repair, one reduce")
            XCTAssertTrue(isRepairCall(stub.calls[2]))
            XCTAssertTrue(stub.calls[2].prompt.contains("Text:\n{bad"))
            XCTAssertEqual(stub.calls[2].maxTokens, stub.calls[0].maxTokens, "the repair gets the part's output cap")
            XCTAssertEqual(stub.calls.filter(isRepairCall).count, 1)
            XCTAssertEqual(outcome.factsSource, .mapJSON)
            XCTAssertTrue(try XCTUnwrap(stub.calls.last).prompt.contains("NOTE-02"), "the repaired part reaches the reduce")
            XCTAssertNil(service.warningMessage)
        }
    }

    func testAPartWithBrokenJSONSwitchesTheWholeRunToTheMarkdownFallback() async throws {
        for speakers in [true, false] {
            let transcript = makeMapTranscript(speakers: speakers)
            let parts = try await mapCallCount(for: transcript)
            let reduceReply = notes(actionItems: ["**Youri** — Plan demo"])
            let stub = StubLLMProvider(
                promptTokenBudget: smallBudget,
                outcomes: [.success(note(1)), .success("{bad"), .success("{still bad")]
                    + (3...parts).map { .success(note($0)) }
                    + [.success(reduceReply)]
            )
            let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

            let outcome = try await service.summarizeWithFacts(meeting: makeMeeting(transcript: transcript))

            XCTAssertEqual(stub.calls.count, parts + 2)
            let reduce = try XCTUnwrap(stub.calls.last).prompt
            XCTAssertFalse(reduce.contains(SummarizationService.reducedActionItemsHeading), "no action-item list after a fallback")
            XCTAssertTrue(reduce.contains("{bad"), "the unreadable part's raw text is its note")
            XCTAssertTrue(reduce.contains("NOTE-01") && reduce.contains(String(format: "NOTE-%02d", parts)))
            XCTAssertEqual(outcome.factsSource, .markdownFallback)
            XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Plan demo"])
            XCTAssertTrue(try XCTUnwrap(service.warningMessage).contains(SummarizationService.factsFallbackWarning))
        }
    }

    /// The fallback keeps a decoded part's to-do that the reduce's markdown
    /// left out, and collapses one it repeated.
    func testTheMarkdownFallbackKeepsTheDecodedPartsActionItems() async throws {
        let transcript = makeMapTranscript(speakers: true)
        let parts = try await mapCallCount(for: transcript)
        let withItems = SummaryFixtures.partJSON(
            topic: "NOTE-01", actionItems: [("Plan demo", "Youri"), ("Bel de leverancier over de prijs", "Kim")]
        )
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success(withItems), .success("{bad"), .success("{still bad")]
                + (3...parts).map { .success(note($0)) }
                + [.success(notes(actionItems: ["**Youri** — Plan demo"]))]
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        let outcome = try await service.summarizeWithFacts(meeting: makeMeeting(transcript: transcript))

        XCTAssertEqual(outcome.factsSource, .markdownFallback)
        XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Plan demo", "Bel de leverancier over de prijs"])
    }

    func testRetryReusesCachedFactsParts() async throws {
        for speakers in [true, false] {
            let transcript = makeMapTranscript(speakers: speakers)
            let meeting = makeMeeting(transcript: transcript)
            let first = SummaryFixtures.partJSON(topic: "NOTE-01", actionItems: [("Stuur offerte", "Kim")])
            let stub = StubLLMProvider(
                promptTokenBudget: smallBudget,
                outcomes: [
                    .success(first), .success("{bad"), .success(note(2)),
                    .failure(StubLLMProvider.transientFailure()), .failure(StubLLMProvider.transientFailure()),
                    .success(SummaryFixtures.partJSON(topic: "NOTE-LATER"))
                ]
            )
            let service = SummarizationService(
                providerFactory: { stub },
                userDefaults: makeMapReduceDefaults(),
                retryPolicy: LLMRetryPolicy(maxAttempts: 2, baseDelay: 0, sleep: { _ in })
            )

            do {
                _ = try await service.summarizeWithFacts(meeting: meeting)
                XCTFail("part 3 failed on every attempt")
            } catch SummarizationError.requestFailed {}
            XCTAssertEqual(stub.calls.count, 5, "part 1, part 2 + its repair, then part 3 twice")

            let outcome = try await service.summarizeWithFacts(meeting: meeting)
            let retryCalls = Array(stub.calls.dropFirst(5))
            XCTAssertTrue(retryCalls[0].prompt.hasPrefix("You are extracting facts from part 3 of"))
            XCTAssertFalse(retryCalls.contains {
                $0.prompt.hasPrefix("You are extracting facts from part 1 of")
                    || $0.prompt.hasPrefix("You are extracting facts from part 2 of")
                    || isRepairCall($0)
            }, "parts 1-2 (including the repaired one) come from the cache")
            XCTAssertEqual(outcome.factsSource, .mapJSON)
            XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Stuur offerte"], "the cached part's facts survive")
            let reduce = try XCTUnwrap(retryCalls.last).prompt
            XCTAssertTrue(reduce.contains("NOTE-01") && reduce.contains("NOTE-02"))
        }
    }

    func testChangedPrepInvalidatesTheMapCache() async throws {
        let transcript = makeMapTranscript(speakers: true)
        let meeting = makeMeeting(transcript: transcript)
        let prep = PrepBox(value: "Vraag naar budget A")
        // The focus is part of each map prompt, so it shapes the part count.
        let probe = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        _ = try await makeService(probe, defaults: makeMapReduceDefaults(), prep: "Vraag naar budget A")
            .summarize(meeting: makeMeeting(transcript: transcript))
        let parts = probe.calls.filter(isMapCall).count
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success(note(1)), .success(note(2)), .failure(LLMProviderError.requestFailed(provider: "Stub", kind: .httpStatus(400), message: "bad"))]
                + numberedNotes()
        )
        let service = SummarizationService(
            providerFactory: { stub },
            userDefaults: makeMapReduceDefaults(),
            attendeeProvider: StaticAttendeeProvider(attendees: []),
            prepLoader: { _, _ in prep.value }
        )

        _ = try? await service.summarize(meeting: meeting)
        XCTAssertEqual(stub.calls.count, 3, "parts 1-2 cached, part 3 failed")

        // Same length, so only the focus (not the part size) differs.
        prep.value = "Vraag naar budget B"
        _ = try await service.summarize(meeting: meeting)

        let rerun = stub.calls.dropFirst(3)
        XCTAssertEqual(rerun.filter(isMapCall).count, parts, "every part is re-extracted")
        XCTAssertTrue(try XCTUnwrap(rerun.first).prompt.hasPrefix("You are extracting facts from part 1 of"))
        XCTAssertTrue(try XCTUnwrap(rerun.first).prompt.contains("Vraag naar budget B"))
    }

    func testJSONMapOutputCapForALocalAndAClaudeBudget() {
        let local = SummarizationService.chunkTokens(budget: LLMPromptSupport.localPromptTokenBudget, mapPromptOverhead: 700)
        XCTAssertEqual(local, 4_000)
        XCTAssertEqual(SummarizationService.mapJSONOutputTokens(chunkTokens: local, thinkingEnabled: false), 1_500)
        let claude = SummarizationService.chunkTokens(budget: 100_000, mapPromptOverhead: 700)
        XCTAssertEqual(claude, 12_500)
        XCTAssertEqual(SummarizationService.mapJSONOutputTokens(chunkTokens: claude, thinkingEnabled: false), 2_500)
        XCTAssertNil(SummarizationService.mapJSONOutputTokens(chunkTokens: claude, thinkingEnabled: true))
        XCTAssertEqual(LLMPromptSupport.mapOutputTokens, 900, "merge calls keep the old cap")
    }

    func testMapPromptGolden() {
        let meeting = Meeting(title: "EHDS", date: SummaryFixtures.meetingDate, participants: ["Kim"], status: .completed)
        let context = SummarizationService.PromptContext(
            meeting: meeting,
            template: "T {{transcript}}",
            freeformNotes: "",
            terminologyBlock: "",
            userName: "Youri",
            participantsLine: "Kim, Youri (me)",
            prep: nil,
            thinkingEnabled: false,
            calendar: SummaryFixtures.amsterdamCalendar
        )
        let chunk = TranscriptChunk(index: 1, text: "[01:00] Kim: Ik mail de offerte.", startLabel: "01:00", endLabel: "02:00")

        let prompt = SummarizationService.mapPrompt(chunk: chunk, total: 3, context: context)

        let expected = """
        You are extracting facts from part 2 of 3 of a meeting transcript
        (01:00–02:00) so it can be summarized later.
        Meeting: EHDS. Participants: Kim, Youri (me). The note-taker is Youri.
        Return only one JSON object, no prose and no code fence, with exactly this shape:
        \(SummaryFactsPrompt.objectShape)
        \(SummaryFactsPrompt.rules(meetingDate: SummaryFixtures.meetingDate, calendar: SummaryFixtures.amsterdamCalendar))
        - Keep each "quote" to about 15 words at most.
        Only use this part of the transcript.

        Transcript part:
        [01:00] Kim: Ik mail de offerte.
        """
        XCTAssertEqual(prompt, expected)
    }

    /// The reduce's markdown lists an item the parts did not: it is kept, with
    /// the warning, as in the single pass.
    func testAReduceWithMoreActionItemsThanTheMapFactsKeepsThemWithTheWarning() async throws {
        for speakers in [true, false] {
            let part = SummaryFixtures.partJSON(topic: "Offerte", actionItems: [("Stuur offerte", "Kim")])
            let transcript = makeMapTranscript(speakers: speakers)
            let parts = try await mapCallCount(for: transcript)
            let stub = StubLLMProvider(
                promptTokenBudget: smallBudget,
                outcomes: Array(repeating: .success(part), count: parts)
                    + [.success(notes(actionItems: ["**Kim** — Stuur offerte", "**Youri** — Plan de demo met de leverancier"]))]
            )
            let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

            let outcome = try await service.summarizeWithFacts(meeting: makeMeeting(transcript: transcript))

            XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Stuur offerte", "Plan de demo met de leverancier"])
            XCTAssertEqual(outcome.facts.actionItems.first?.confidence, 0.8, "the part's item keeps its data")
            XCTAssertEqual(outcome.factsSource, .markdownFallback)
            XCTAssertTrue(try XCTUnwrap(service.warningMessage).contains(SummarizationService.factsFallbackWarning))
        }
    }

    func testAChangedMeetingDateInvalidatesTheMapCache() async throws {
        let transcript = makeMapTranscript(speakers: true)
        let parts = try await mapCallCount(for: transcript)
        let meeting = makeMeeting(transcript: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success(note(1)), .success(note(2)), .failure(LLMProviderError.requestFailed(provider: "Stub", kind: .httpStatus(400), message: "bad"))]
                + numberedNotes()
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try? await service.summarize(meeting: meeting)
        XCTAssertEqual(stub.calls.count, 3)

        meeting.date = meeting.date.addingTimeInterval(-86_400)
        _ = try await service.summarize(meeting: meeting)

        XCTAssertEqual(stub.calls.dropFirst(3).filter(isMapCall).count, parts, "due dates resolve against the new date")
    }

    func testRetryTriesAMarkdownFallbackPartsJSONAgain() async throws {
        let transcript = makeMapTranscript(speakers: true)
        let meeting = makeMeeting(transcript: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [
                .success(note(1)), .success("{bad"), .success("{still bad"),
                .failure(LLMProviderError.requestFailed(provider: "Stub", kind: .httpStatus(400), message: "bad")),
            ] + numberedNotes()
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try? await service.summarize(meeting: meeting)
        XCTAssertEqual(stub.calls.count, 4, "part 1, part 2 + repair, part 3 failed")

        let outcome = try await service.summarizeWithFacts(meeting: meeting)

        let retryCalls = Array(stub.calls.dropFirst(4))
        XCTAssertTrue(retryCalls[0].prompt.hasPrefix("You are extracting facts from part 2 of"), "part 1 is cached, part 2 is not")
        XCTAssertFalse(retryCalls.contains { $0.prompt.hasPrefix("You are extracting facts from part 1 of") })
        XCTAssertEqual(outcome.factsSource, .mapJSON)
    }

    /// A template that fills the whole budget still leaves the reduce some notes.
    func testATemplateThatFillsTheBudgetKeepsTheMinimumNotes() async throws {
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: [.success(SummaryFixtures.bulkyPartJSON(chars: 600))])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults(padding: 6_000))

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeMapTranscript(speakers: true)))

        let reduce = try XCTUnwrap(stub.calls.last).prompt
        XCTAssertTrue(reduce.contains("## Part 1/"), "the head of the notes survives")
        XCTAssertTrue(reduce.contains("transcript truncated"))
        let notesStart = try XCTUnwrap(reduce.range(of: SummarizationService.condensedNotesPreamble))
        let notesEnd = try XCTUnwrap(reduce.range(of: "\n\n" + SummarizationService.reducedActionItemsHeading))
        let notes = String(reduce[notesStart.lowerBound..<notesEnd.lowerBound])
        XCTAssertEqual(LLMPromptSupport.budgetTokens(notes), SummarizationService.minReduceNotesTokens, accuracy: 2)
        XCTAssertEqual(service.warningMessage, SummarizationService.shortenedWarning)
    }

    func testTheOnePassCapAppliesToTheBudget() {
        XCTAssertEqual(SummarizationService.onePassTokenCap, 25_000)
        XCTAssertEqual(SummarizationService.onePassBudget(100_000), 25_000)
        XCTAssertEqual(SummarizationService.onePassBudget(6_000), 6_000)
        XCTAssertEqual(SummarizationService.chunkTokens(budget: 100_000, mapPromptOverhead: 1_000), 12_500)
    }

    // MARK: - Prompt context (focus block, marked participants)

    /// A service that never reaches EventKit or the vault: fixed attendees and a
    /// stubbed prep loader.
    private func makeService(
        _ stub: StubLLMProvider,
        defaults: UserDefaults? = nil,
        attendees: [MeetingAttendee] = [],
        prep: String? = nil
    ) -> SummarizationService {
        SummarizationService(
            providerFactory: { stub },
            userDefaults: defaults ?? makeDefaults(),
            attendeeProvider: StaticAttendeeProvider(attendees: attendees),
            prepLoader: { _, _ in prep }
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// `[mm:ss] Kim: …` lines (or `[mm:ss] …` without the speaker) of at least `chars`.
    private func makeTranscript(chars: Int, speakers: Bool) -> String {
        var lines: [String] = []
        var total = 0
        var i = 0
        while total < chars {
            let speaker = speakers ? (i.isMultiple(of: 2) ? "Kim: " : "Youri: ") : ""
            let line = String(format: "[%02d:%02d] %@punt %04d over het budget.", i / 60, i % 60, speaker, i)
            lines.append(line)
            total += line.count + 1
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    func testPromptPutsFocusBeforeTranscript() async throws {
        for speakers in [true, false] {
            let meeting = makeMeeting(transcript: makeTranscript(chars: 300, speakers: speakers))
            meeting.userNotes = "Kim twijfelt"
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))])
            let service = makeService(stub, prep: "Vraag naar budget")

            _ = try await service.summarize(meeting: meeting)

            XCTAssertEqual(stub.calls.count, 1)
            let prompt = try XCTUnwrap(stub.calls.first?.prompt)
            let focus = try XCTUnwrap(prompt.range(of: "What the user cares about"))
            let transcript = try XCTUnwrap(prompt.range(of: "Transcript:"))
            XCTAssertLessThan(focus.lowerBound, transcript.lowerBound)
            XCTAssertEqual(occurrences(of: "Vraag naar budget", in: prompt), 1)
            XCTAssertEqual(occurrences(of: "Kim twijfelt", in: prompt), 1)
            XCTAssertFalse(prompt.contains("{{user_focus}}"))
        }
    }

    func testFocusIsTrimmedBeforeTheTranscript() async throws {
        for speakers in [true, false] {
            let transcript = makeTranscript(chars: 3_600, speakers: speakers)
            let meeting = makeMeeting(transcript: transcript)
            // The single pass also carries the JSON facts instruction; the budget
            // grows by exactly its cost so the focus is trimmed as before.
            let budget = smallBudget + LLMPromptSupport.budgetTokens(
                "\n\n" + SummaryFactsPrompt.singlePassInstruction(meetingDate: meeting.date, calendar: .current)
            )
            let stub = StubLLMProvider(promptTokenBudget: budget, outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))])
            let service = makeService(
                stub,
                defaults: makeMapReduceDefaults(),
                prep: String(repeating: "Vraag naar budget. ", count: 211)
            )

            _ = try await service.summarize(meeting: meeting)

            XCTAssertEqual(stub.calls.count, 1, "a trimmed focus keeps the call single-pass")
            let prompt = try XCTUnwrap(stub.calls.first?.prompt)
            XCTAssertTrue(prompt.contains(transcript), "the transcript is never trimmed for the focus")
            XCTAssertTrue(prompt.contains("What the user cares about"))
            XCTAssertTrue(prompt.contains("…"))
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(prompt), budget)
        }
    }

    func testTooLittleRoomForTheFocusGoesMapReduceWithTheFullFocusInTheReduce() async throws {
        let prep = "Vraag naar budget en planning."
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        let service = makeService(stub, defaults: makeMapReduceDefaults(), prep: prep)

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeTranscript(chars: 4_200, speakers: true)))

        XCTAssertFalse(stub.calls.filter(isMapCall).isEmpty)
        let reduce = try XCTUnwrap(stub.calls.last?.prompt)
        XCTAssertTrue(reduce.contains("Prep:\n" + prep))
    }

    func testCustomTemplateWithFreeformNotesKeepsNotesThere() async throws {
        let defaults = makeDefaults()
        defaults.set("T {{transcript}} N {{freeform_notes}}", forKey: AppPreferenceKey.summaryPromptTemplate)
        let meeting = makeMeeting()
        meeting.userNotes = "Kim twijfelt"
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))])
        let service = makeService(stub, defaults: defaults, prep: "Vraag naar budget")

        _ = try await service.summarize(meeting: meeting)

        let prompt = try XCTUnwrap(stub.calls.first?.prompt)
        XCTAssertTrue(prompt.contains(" N Kim twijfelt"))
        XCTAssertEqual(occurrences(of: "Kim twijfelt", in: prompt), 1)
        XCTAssertFalse(prompt.contains("User notes:"), "the notes stay in {{freeform_notes}}")
        let focus = try XCTUnwrap(prompt.range(of: "What the user cares about"))
        let transcriptLine = try XCTUnwrap(prompt.range(of: "T Alice: We ship Friday."))
        XCTAssertLessThan(focus.lowerBound, transcriptLine.lowerBound)
        XCTAssertTrue(prompt.contains("Prep:\nVraag naar budget\n\nT Alice"))
    }

    func testPromptListsUserAsMe() async throws {
        for speakers in [true, false] {
            let defaults = makeDefaults()
            defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)
            let meeting = Meeting(title: "Sync", date: .now, participants: ["Kim"], status: .completed)
            meeting.transcript = makeTranscript(chars: 200, speakers: speakers)
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))])
            let service = makeService(stub, defaults: defaults)

            _ = try await service.summarize(meeting: meeting)

            XCTAssertTrue(try XCTUnwrap(stub.calls.first?.prompt).contains("Participants: Kim, Youri (me)\n"))
        }
    }

    func testPromptCarriesAttendeeEmails() async throws {
        let defaults = makeDefaults()
        defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)
        let meeting = Meeting(title: "Sync", date: .now, participants: ["Kim"], status: .completed)
        meeting.transcript = "[00:01] Kim: We ship Friday."
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts("# Summary\nDone."))])
        let service = makeService(
            stub,
            defaults: defaults,
            attendees: [MeetingAttendee(name: "kim", email: "kim@partner.nl", isCurrentUser: false)]
        )

        _ = try await service.summarize(meeting: meeting)

        XCTAssertTrue(try XCTUnwrap(stub.calls.first?.prompt).contains("Participants: Kim <kim@partner.nl>, Youri (me)\n"))
    }

    func testMapPromptsUseTheMarkedParticipantsLine() async throws {
        let meeting = Meeting(title: "EHDS", date: .now, participants: ["Kim"], status: .completed)
        meeting.transcript = makeLongTranscript(chars: 20_000)
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes())
        let service = makeService(stub, defaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: meeting)

        let map = try XCTUnwrap(stub.calls.first(where: isMapCall)?.prompt)
        XCTAssertTrue(map.contains("Meeting: EHDS. Participants: Kim, Youri (me). The note-taker is Youri."))
    }

    // MARK: - Facts in the single pass (JSON block, repair, markdown fallback)

    /// Dutch notes with one decision and one action item for Kim.
    private let kimNotes = """
    # Samenvatting
    Kim stuurt de offerte deze week.

    ## Offerte
    - **prijs:** akkoord

    ## Besluiten
    - We gaan door met de offerte

    ## Actiepunten
    - **Kim** — Mail de offerte

    ## Risico's en blockers

    ## Opvolging
    """

    /// The verification call's reply for `kimActionJSON`'s one claim (its quote
    /// is in `factsTranscript`, so every run with it makes that call).
    private let kimVerdict: Result<String, Error> = .success(#"[{"id": "a1", "supported": true, "reason": "Kim zegt het."}]"#)

    /// `kimNotes` as stored after `kimActionJSON`: the Action Items bullet is
    /// rendered from the facts; the JSON has no decisions, so the markdown's stay.
    private var renderedKimNotes: String {
        kimNotes.replacingOccurrences(
            of: "- **Kim** — Mail de offerte\n",
            with: "- **Kim** — Mail de offerte (2026-11-06) [00:10]\n"
        )
    }

    private func notes(actionItems: [String]) -> String {
        """
        # Samenvatting
        Korte meeting.

        ## Besluiten

        ## Actiepunten
        \(actionItems.map { "- " + $0 }.joined(separator: "\n"))

        ## Risico's en blockers

        ## Opvolging
        """
    }

    /// The same two lines with `Kim: ` / `Youri: ` speaker labels or without.
    private func factsTranscript(speakers: Bool) -> String {
        speakers
            ? "[00:10] Kim: Ik mail de offerte vrijdag.\n[00:20] Youri: Prima, dank je."
            : "[00:10] Ik mail de offerte vrijdag.\n[00:20] Prima, dank je."
    }

    private func makeFactsMeeting(speakers: Bool) -> Meeting {
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate, status: .completed)
        meeting.transcript = factsTranscript(speakers: speakers)
        return meeting
    }

    private func makeFactsService(_ stub: StubLLMProvider, thinking: Bool = false) -> SummarizationService {
        let defaults = makeDefaults()
        defaults.set(thinking, forKey: AppPreferenceKey.summaryThinkingEnabled)
        return SummarizationService(
            providerFactory: { stub },
            userDefaults: defaults,
            attendeeProvider: StaticAttendeeProvider(attendees: []),
            prepLoader: { _, _ in nil },
            calendar: SummaryFixtures.amsterdamCalendar
        )
    }

    func testSinglePassAsksForTheJSONBlockInTheSameCall() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(kimNotes, json: SummaryFixtures.kimActionJSON)), kimVerdict])
            let service = makeFactsService(stub)

            _ = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 2, "the summary, then only the verification call")
            XCTAssertTrue(stub.calls[1].prompt.hasPrefix("You are checking meeting notes"))
            let prompt = try XCTUnwrap(stub.calls.first?.prompt)
            XCTAssertTrue(prompt.contains("add one fenced code block that starts with ```json"))
            XCTAssertTrue(prompt.contains("2026-11-04"))
            XCTAssertTrue(prompt.contains(factsTranscript(speakers: speakers)))
            XCTAssertTrue(prompt.hasSuffix(LLMPromptSupport.noThinkSuffix), "the thinking switch comes after the JSON instruction")
        }
    }

    // MARK: - Templates (B5)

    /// `makeFactsService` with both template keys set explicitly (R12).
    private func makeTemplateService(_ stub: StubLLMProvider, legacyPrompt: String? = nil) -> SummarizationService {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.summaryThinkingEnabled)
        defaults.set("", forKey: AppPreferenceKey.summaryTemplates)
        if let legacyPrompt {
            defaults.set(legacyPrompt, forKey: AppPreferenceKey.summaryPromptTemplate)
        } else {
            defaults.removeObject(forKey: AppPreferenceKey.summaryPromptTemplate)
        }
        defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)
        defaults.set(false, forKey: AppPreferenceKey.includeUnassignedActionItems)
        return SummarizationService(
            providerFactory: { stub },
            userDefaults: defaults,
            attendeeProvider: StaticAttendeeProvider(attendees: []),
            prepLoader: { _, _ in nil },
            calendar: SummaryFixtures.amsterdamCalendar
        )
    }

    private func templateStub() -> StubLLMProvider {
        StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(kimNotes, json: SummaryFixtures.kimActionJSON)), kimVerdict])
    }

    func testAutoSelectedTemplateIsUsedAndReturned() async throws {
        for speakers in [true, false] {
            let stub = templateStub()
            let service = makeTemplateService(stub)
            let meeting = makeFactsMeeting(speakers: speakers)
            meeting.title = "Daily stand-up"

            let outcome = try await service.summarizeWithFacts(meeting: meeting)

            let prompt = try XCTUnwrap(stub.calls.first?.prompt)
            XCTAssertTrue(prompt.contains("## Per persoon"))
            XCTAssertFalse(prompt.contains("2-5 thematic sections"))
            XCTAssertTrue(prompt.contains("add one fenced code block that starts with ```json"), "the JSON instruction still follows")
            XCTAssertTrue(prompt.contains(factsTranscript(speakers: speakers)))
            XCTAssertEqual(outcome.templateID, "standup")
            XCTAssertEqual(outcome.facts.actionItems.map(\.owner), ["Kim"], "structured facts still come through")
        }
    }

    func testMeetingOverrideBeatsSelector() async throws {
        let stub = templateStub()
        let service = makeTemplateService(stub)
        let meeting = makeFactsMeeting(speakers: true)
        meeting.title = "Daily stand-up"
        meeting.summaryTemplateID = "workshop"

        let outcome = try await service.summarizeWithFacts(meeting: meeting)

        let prompt = try XCTUnwrap(stub.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("## Parkeerplaats"))
        XCTAssertFalse(prompt.contains("## Per persoon"))
        XCTAssertEqual(outcome.templateID, "workshop")
    }

    func testExplicitTemplateBeatsMeetingOverride() async throws {
        let stub = templateStub()
        let service = makeTemplateService(stub)
        let meeting = makeFactsMeeting(speakers: false)
        meeting.title = "Daily stand-up"
        meeting.summaryTemplateID = "workshop"

        let outcome = try await service.summarizeWithFacts(meeting: meeting, templateID: "refinement")

        let prompt = try XCTUnwrap(stub.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("- **Estimate:** 5 SP"))
        XCTAssertFalse(prompt.contains("## Parkeerplaats"))
        XCTAssertEqual(outcome.templateID, "refinement")
    }

    /// A stored id that no longer exists (deleted custom template) is General.
    func testUnknownMeetingTemplateFallsBackToGeneral() async throws {
        let stub = templateStub()
        let service = makeTemplateService(stub)
        let meeting = makeFactsMeeting(speakers: true)
        meeting.summaryTemplateID = "custom-gone"

        let outcome = try await service.summarizeWithFacts(meeting: meeting)

        XCTAssertTrue(try XCTUnwrap(stub.calls.first?.prompt).contains("2-5 thematic sections"))
        XCTAssertEqual(outcome.templateID, "general")
    }

    /// The user's customised legacy prompt is General's prompt.
    func testLegacyCustomPromptIsTheGeneralTemplate() async throws {
        let stub = templateStub()
        let service = makeTemplateService(stub, legacyPrompt: "MY OWN PROMPT {{transcript}}")
        let meeting = makeFactsMeeting(speakers: true)

        let outcome = try await service.summarizeWithFacts(meeting: meeting)

        XCTAssertTrue(try XCTUnwrap(stub.calls.first?.prompt).hasPrefix("MY OWN PROMPT "))
        XCTAssertEqual(outcome.templateID, "general")
    }

    func testBackgroundSummaryUsesButDoesNotStoreTheAutoSelectedTemplate() async throws {
        let stub = templateStub()
        let service = makeTemplateService(stub)
        let context = try makeTodoContext()
        let meeting = makeFactsMeeting(speakers: true)
        meeting.title = "Bila Martijn"
        context.insert(meeting)

        try await runInBackground(service, meeting, context)

        XCTAssertNil(meeting.summaryTemplateID, "auto-picked templates are not stored as overrides")
        XCTAssertTrue(try XCTUnwrap(stub.calls.first?.prompt).contains("## Hoe gaat het"))
    }

    func testJSONBlockIsStrippedFromTheStoredSummary() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(kimNotes, json: SummaryFixtures.kimActionJSON)), kimVerdict])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertFalse(outcome.parsed.rawMarkdown.contains("```"))
            XCTAssertEqual(outcome.parsed.todoTexts, ["**Kim** — Mail de offerte (2026-11-06) [00:10]"],
                           "the Action Items section is rendered from the facts")
            XCTAssertEqual(outcome.factsSource, .singlePassJSON)
            XCTAssertEqual(outcome.facts.actionItems.first?.owner, "Kim")
            XCTAssertEqual(outcome.facts.actionItems.first?.due, "2026-11-06", "vrijdag resolves against the meeting date")
            XCTAssertEqual(outcome.templateID, "general")
            XCTAssertNil(service.warningMessage)
        }
    }

    func testSummarizeReturnsTheParsedPartOfTheOutcome() async throws {
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(kimNotes, json: SummaryFixtures.kimActionJSON)), kimVerdict])
        let service = makeFactsService(stub)

        let parsed = try await service.summarize(meeting: makeFactsMeeting(speakers: true))

        XCTAssertEqual(parsed.rawMarkdown, renderedKimNotes)
        XCTAssertEqual(stub.calls.count, 2, "summary + verification")
    }

    func testInvalidJSONGetsOneRepairCall() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [
                .success(SummaryFixtures.withFacts(kimNotes, json: "{oops")),
                .success(SummaryFixtures.kimActionJSON),
                kimVerdict
            ])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 3, "summary, repair, verification")
            let repair = stub.calls[1]
            XCTAssertTrue(repair.prompt.hasPrefix("The text below was meant to be one JSON object"))
            XCTAssertTrue(repair.prompt.contains("Text:\n{oops"))
            XCTAssertEqual(repair.maxTokens, LLMPromptSupport.cappedOutputTokens)
            XCTAssertEqual(outcome.factsSource, .repairedJSON)
            XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Mail de offerte"])
            XCTAssertFalse(outcome.parsed.rawMarkdown.contains("```"))
            XCTAssertNil(service.warningMessage)
        }
    }

    func testTheRepairCallIsUncappedWhenThinkingIsOn() async throws {
        let stub = StubLLMProvider(outcomes: [
            .success(SummaryFixtures.withFacts(kimNotes, json: "{oops")),
            .success(SummaryFixtures.kimActionJSON),
            kimVerdict
        ])
        let service = makeFactsService(stub, thinking: true)

        _ = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: true))

        XCTAssertEqual(stub.calls.count, 3)
        XCTAssertNil(stub.calls[1].maxTokens)
    }

    /// Controller requirement (a): a truncated block goes to the repair call
    /// as-is, not cut at an inner `}` by `extractJSONObject`.
    func testRepairGetsTheRawTextOfATruncatedBlock() async throws {
        for speakers in [true, false] {
            let truncated = #"{"topics":["Offerte"],"action_items":[{"task":"Mail de offerte","owner":"Kim"},{"task":"Bel de lev"#
            let stub = StubLLMProvider(outcomes: [
                .success(kimNotes + "\n\n```json\n" + truncated),
                .success(SummaryFixtures.kimActionJSON),
                kimVerdict
            ])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 3)
            XCTAssertTrue(stub.calls[1].prompt.contains("Text:\n" + truncated))
            XCTAssertEqual(outcome.factsSource, .repairedJSON)
            XCTAssertFalse(outcome.parsed.rawMarkdown.contains("```"))
        }
    }

    func testMissingBlockRebuildsFromClosingSectionsWithoutTheTranscript() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [.success(kimNotes), .success(SummaryFixtures.kimActionJSON), kimVerdict])
            let service = makeFactsService(stub)
            let meeting = makeFactsMeeting(speakers: speakers)

            let outcome = try await service.summarizeWithFacts(meeting: meeting)

            XCTAssertEqual(stub.calls.count, 3, "summary, rebuild, verification")
            let rebuild = stub.calls[1].prompt
            XCTAssertTrue(rebuild.hasPrefix("These are the closing sections"))
            XCTAssertFalse(rebuild.contains(factsTranscript(speakers: speakers)))
            XCTAssertFalse(rebuild.contains("Ik mail de offerte vrijdag"))
            XCTAssertTrue(rebuild.contains("## Besluiten\n- We gaan door met de offerte"))
            XCTAssertTrue(rebuild.contains("## Actiepunten\n- **Kim** — Mail de offerte"))
            XCTAssertFalse(rebuild.contains("**prijs:**"), "only the Decisions and Action Items sections")
            XCTAssertFalse(rebuild.contains("Samenvatting"))
            XCTAssertTrue(rebuild.contains("2026-11-04"))
            XCTAssertEqual(outcome.factsSource, .repairedJSON)
            XCTAssertNil(service.warningMessage)
        }
    }

    func testBrokenJSONAfterRepairFallsBackToMarkdownItems() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [
                .success(notes(actionItems: ["**Youri** — Mail Kim"])),
                .success("still {bad")
            ])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 2)
            XCTAssertEqual(outcome.factsSource, .markdownFallback)
            XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Mail Kim"])
            XCTAssertEqual(outcome.facts.actionItems.first?.owner, "Youri")
            XCTAssertTrue(try XCTUnwrap(service.warningMessage).contains(SummarizationService.factsFallbackWarning))
        }
    }

    func testInvalidJSONTwiceFallsBackToMarkdownItems() async throws {
        let stub = StubLLMProvider(outcomes: [
            .success(SummaryFixtures.withFacts(notes(actionItems: ["**Youri** — Mail Kim"]), json: "{oops")),
            .success("{\"action_items\": [}")
        ])
        let service = makeFactsService(stub)

        let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: true))

        XCTAssertEqual(stub.calls.count, 2, "one repair attempt only")
        XCTAssertEqual(outcome.factsSource, .markdownFallback)
        XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Mail Kim"])
        XCTAssertEqual(service.warningMessage, SummarizationService.factsFallbackWarning)
    }

    /// Controller requirement (b): a repair that decodes but lost action items
    /// the markdown has never drops the to-dos to fewer.
    func testARepairWithFewerActionItemsThanTheMarkdownUsesTheMarkdownItems() async throws {
        let markdown = notes(actionItems: ["**Kim** — Mail de offerte", "**Youri** — Plan de demo"])
        for speakers in [true, false] {
            for firstReply in [SummaryFixtures.withFacts(markdown, json: "{oops"), markdown] {
                let stub = StubLLMProvider(outcomes: [.success(firstReply), .success(SummaryFixtures.kimActionJSON)])
                let service = makeFactsService(stub)

                let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

                XCTAssertEqual(stub.calls.count, 2)
                XCTAssertEqual(outcome.factsSource, .markdownFallback)
                XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Mail de offerte", "Plan de demo"])
                XCTAssertEqual(outcome.facts.actionItems.map(\.owner), ["Kim", "Youri"])
                XCTAssertEqual(outcome.facts.topics, ["Offerte"], "the rest of the repaired facts is kept")
                XCTAssertTrue(try XCTUnwrap(service.warningMessage).contains(SummarizationService.factsFallbackWarning))
            }
        }
    }

    func testARepairCallThatFailsFallsBackToMarkdownItems() async throws {
        let stub = StubLLMProvider(outcomes: [
            .success(notes(actionItems: ["**Youri** — Mail Kim"])),
            .failure(LLMProviderError.requestFailed(provider: "Stub", kind: .httpStatus(400), message: "bad"))
        ])
        let service = makeFactsService(stub)

        let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: true))

        XCTAssertEqual(outcome.factsSource, .markdownFallback)
        XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Mail Kim"])
        XCTAssertEqual(service.warningMessage, SummarizationService.factsFallbackWarning)
        XCTAssertNil(service.errorMessage)
    }

    func testCancellationDuringTheRepairCallPropagates() async throws {
        let stub = StubLLMProvider(outcomes: [.success(kimNotes), .failure(CancellationError())])
        let service = makeFactsService(stub)

        do {
            _ = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: true))
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
            // expected
        }
    }

    func testTheFallbackWarningJoinsTheTruncationWarning() async throws {
        let stub = StubLLMProvider(
            outcomes: [.success(notes(actionItems: ["**Youri** — Mail Kim"])), .success("still {bad")],
            truncatedFlags: [true, false]
        )
        let service = makeFactsService(stub)

        _ = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: true))

        XCTAssertEqual(
            service.warningMessage,
            "Summary may be truncated: Stub reached its output length limit. " + SummarizationService.factsFallbackWarning
        )
    }

    func testPhaseShowsRepairing() async throws {
        for speakers in [true, false] {
            let recorder = PhaseRecorder()
            let stub = StubLLMProvider(
                outcomes: [.success(SummaryFixtures.withFacts(kimNotes, json: "{oops")), .success(SummaryFixtures.kimActionJSON), kimVerdict],
                onGenerate: { recorder.record() }
            )
            let service = makeFactsService(stub)
            recorder.service = service

            _ = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(recorder.phases, [.sending, .repairing, .verifying])
            XCTAssertEqual(recorder.statuses[1], "Repairing the structured notes…")
            XCTAssertEqual(service.phase, .idle)
        }
    }

    /// Review ruling 1: "never fewer to-dos silently" holds for a valid block too.
    func testAValidBlockWithFewerActionItemsThanTheMarkdownUsesTheMarkdownItems() async throws {
        let markdown = notes(actionItems: ["**Kim** — Mail de offerte", "**Youri** — Plan de demo", "**?** — Boek een zaal"])
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(markdown, json: SummaryFixtures.kimActionJSON))])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 1, "a valid block needs no repair call")
            XCTAssertEqual(outcome.factsSource, .markdownFallback)
            XCTAssertEqual(outcome.facts.actionItems.map(\.task), ["Mail de offerte", "Plan de demo", "Boek een zaal"])
            XCTAssertEqual(outcome.facts.topics, ["Offerte"], "the rest of the block's facts is kept")
            XCTAssertEqual(service.warningMessage, SummarizationService.factsFallbackWarning)
        }
    }

    /// Review 2/3: no block and nothing in the closing sections → no rebuild
    /// call and no warning.
    func testNoBlockAndEmptyClosingSectionsSkipsTheRebuildCall() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [.success(notes(actionItems: []))])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 1)
            XCTAssertEqual(outcome.factsSource, .markdownFallback)
            XCTAssertEqual(outcome.facts, .empty)
            XCTAssertNil(service.warningMessage)
        }
    }

    /// Review 3: an unreadable block means facts were lost, so the warning
    /// shows even when the markdown has no items.
    func testAnUnreadableBlockWarnsEvenWhenTheMarkdownHasNoItems() async throws {
        let stub = StubLLMProvider(outcomes: [
            .success(SummaryFixtures.withFacts(notes(actionItems: []), json: "{oops")),
            .success("still {bad")
        ])
        let service = makeFactsService(stub)

        let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: true))

        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertEqual(outcome.factsSource, .markdownFallback)
        XCTAssertEqual(service.warningMessage, SummarizationService.factsFallbackWarning)
    }

    /// Review 5: a thinking model's reply keeps neither its reasoning nor the JSON.
    func testAThinkingReplyStoresNeitherTheThinkBlockNorTheJSON() async throws {
        for speakers in [true, false] {
            let reply = "<think>Eerst de offerte, dan {\"x\": 1} checken.</think>\n"
                + SummaryFixtures.withFacts(kimNotes, json: SummaryFixtures.kimActionJSON)
            let stub = StubLLMProvider(outcomes: [.success(reply), kimVerdict])
            let service = makeFactsService(stub, thinking: true)

            let outcome = try await service.summarizeWithFacts(meeting: makeFactsMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 2, "summary + verification")
            XCTAssertEqual(outcome.parsed.rawMarkdown, renderedKimNotes)
            XCTAssertFalse(outcome.parsed.rawMarkdown.contains("<think>"))
            XCTAssertFalse(outcome.parsed.rawMarkdown.contains("```"))
            XCTAssertEqual(outcome.factsSource, .singlePassJSON)
            XCTAssertEqual(outcome.facts.actionItems.map(\.owner), ["Kim"])
        }
    }

    func testClosingSectionsUseTheParsersHeadingAliases() {
        let markdown = "# Summary\nx\n\n## Decisions:\n- A\n\n## Risks\n- R\n\n## Actielijst\n- **Kim** — B\n\n## Follow-ups\n- F"
        XCTAssertEqual(
            SummarizationService.closingSections(of: markdown),
            "## Decisions:\n- A\n\n## Actielijst\n- **Kim** — B"
        )
    }

    func testRepairingAndVerifyingStatusMessages() {
        XCTAssertEqual(SummarizationService.repairingStatus, "Repairing the structured notes…")
        XCTAssertEqual(SummarizationService.verifyingStatus, "Checking action items against the transcript…")
    }

    // MARK: - Rendered sections, stored items and proposed to-dos (Task 5)

    // MARK: - Template override persistence

    private let emptyFactsJSON = #"{"topics":[],"decisions":[],"action_items":[],"open_questions":[],"facts":[]}"#

    func testAutoPickedTemplateIsNotStoredAndStaysRederivable() async throws {
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(notes(actionItems: []), json: emptyFactsJSON))])
        let service = makeBackgroundService(stub)
        let context = try makeTodoContext()
        let meeting = makeFactsMeeting(speakers: false)
        meeting.title = "Overleg"
        context.insert(meeting)

        try await runInBackground(service, meeting, context)
        XCTAssertNil(meeting.summaryTemplateID)
        let first = try await service.summarizeWithFacts(meeting: meeting)
        XCTAssertEqual(first.templateID, "general")

        meeting.title = "Daily"
        try await runInBackground(service, meeting, context)
        XCTAssertNil(meeting.summaryTemplateID)
        let second = try await service.summarizeWithFacts(meeting: meeting)
        XCTAssertEqual(second.templateID, "standup")
    }

    func testExplicitTemplateIsPersistedAndWinsNextTime() async throws {
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(notes(actionItems: []), json: emptyFactsJSON))])
        let service = makeBackgroundService(stub)
        let context = try makeTodoContext()
        let meeting = makeFactsMeeting(speakers: false)
        meeting.title = "Daily"
        context.insert(meeting)

        service.summarizeInBackground(meeting: meeting, modelContext: context, templateID: "workshop")
        let deadline = Date().addingTimeInterval(5)
        while service.isSummarizing, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(meeting.summaryTemplateID, "workshop")

        // A later run without an explicit id keeps the override, even though the title says standup.
        try await runInBackground(service, meeting, context)
        XCTAssertEqual(meeting.summaryTemplateID, "workshop")
        let outcome = try await service.summarizeWithFacts(meeting: meeting)
        XCTAssertEqual(outcome.templateID, "workshop")
    }

    /// The "(auto)" template the summary header shows is what the service
    /// would pick now, from the same title, participants and attendees.
    func testAutoTemplateIDMatchesWhatTheServiceWouldPick() async throws {
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(notes(actionItems: []), json: emptyFactsJSON))])
        let defaults = makeDefaults()
        defaults.removeObject(forKey: AppPreferenceKey.summaryPromptTemplate)
        defaults.set("", forKey: AppPreferenceKey.summaryTemplates)
        let meeting = makeFactsMeeting(speakers: false)

        meeting.title = "Overleg"
        XCTAssertEqual(makeService(stub, defaults: defaults).autoTemplateID(for: meeting), SummaryTemplateID.general)

        meeting.title = "Daily Team Link"
        XCTAssertEqual(makeService(stub, defaults: defaults).autoTemplateID(for: meeting), SummaryTemplateID.standup)

        meeting.title = "Overleg"
        let external = makeService(stub, defaults: defaults, attendees: [
            MeetingAttendee(name: "Youri", email: "youri@medicore.nl", isCurrentUser: true),
            MeetingAttendee(name: "Kim", email: "kim@partner.nl", isCurrentUser: false),
        ])
        XCTAssertEqual(external.autoTemplateID(for: meeting), SummaryTemplateID.external)
        // The stored override does not change the auto pick.
        meeting.summaryTemplateID = SummaryTemplateID.workshop
        XCTAssertEqual(external.autoTemplateID(for: meeting), SummaryTemplateID.external)
        let outcome = try await external.summarizeWithFacts(meeting: meeting)
        XCTAssertEqual(outcome.templateID, SummaryTemplateID.workshop)
    }

    func testTemplatesComeFromTheServiceDefaults() {
        let defaults = makeDefaults()
        defaults.removeObject(forKey: AppPreferenceKey.summaryPromptTemplate)
        defaults.set("", forKey: AppPreferenceKey.summaryTemplates)
        SummaryTemplateStore.save(SummaryTemplate(id: "custom-1", name: "Klantdemo", prompt: "p", isBuiltIn: false), in: defaults)
        let service = makeService(StubLLMProvider(outcomes: []), defaults: defaults)
        XCTAssertEqual(service.summaryTemplates().map(\.id).last, "custom-1")
        XCTAssertEqual(service.summaryTemplates().count, SummaryTemplateCatalog.builtIns.count + 1)
    }

    /// Kim's item due vrijdag at 00:10, Youri's at 00:20 without a due date.
    private let kimAndYouriJSON = #"""
    {"topics":["Offerte"],"decisions":[{"text":"We gaan door","quote":"we gaan door","timestamp":"00:05"}],"action_items":[{"task":"Mail de offerte","owner":"Kim","due":"vrijdag","due_is_explicit":true,"confidence":0.8,"quote":"ik mail de offerte","timestamp":"00:10"},{"task":"Plan de demo","owner":"Youri","due":null,"confidence":0.9,"quote":"prima","timestamp":"00:20"}],"open_questions":[],"facts":[]}
    """#

    private func makeTodoContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    /// Only "Youri" is the user; unassigned items are explicitly off (R12).
    private func makeBackgroundService(_ stub: StubLLMProvider) -> SummarizationService {
        let defaults = makeDefaults()
        defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)
        defaults.set(false, forKey: AppPreferenceKey.includeUnassignedActionItems)
        defaults.set(false, forKey: AppPreferenceKey.summaryThinkingEnabled)
        return SummarizationService(
            providerFactory: { stub },
            userDefaults: defaults,
            attendeeProvider: StaticAttendeeProvider(attendees: []),
            prepLoader: { _, _ in nil },
            calendar: SummaryFixtures.amsterdamCalendar
        )
    }

    private func runInBackground(_ service: SummarizationService, _ meeting: Meeting, _ context: ModelContext) async throws {
        service.summarizeInBackground(meeting: meeting, modelContext: context)
        let deadline = Date().addingTimeInterval(5)
        while service.isSummarizing, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(service.isSummarizing)
        XCTAssertNil(service.errorMessage)
    }

    func testBackgroundSummaryStoresAllItemsAndProposesOnlyMine() async throws {
        for speakers in [true, false] {
            let markdown = notes(actionItems: ["**Kim** — Mail de offerte", "**Youri** — Plan de demo"])
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(markdown, json: kimAndYouriJSON)), kimVerdict])
            let service = makeBackgroundService(stub)
            let context = try makeTodoContext()
            let meeting = makeFactsMeeting(speakers: speakers)
            context.insert(meeting)

            try await runInBackground(service, meeting, context)

            XCTAssertEqual(meeting.actionItems.count, 2, "every owner's item is stored on the meeting")
            XCTAssertEqual(meeting.actionItems.map(\.owner), ["Kim", "Youri"])
            XCTAssertNil(meeting.summaryTemplateID, "an auto-picked template is never stored as an override")
            let todos = try context.fetch(FetchDescriptor<TodoItem>())
            XCTAssertEqual(todos.map(\.text), ["Plan de demo"], "only the user's own item becomes a to-do")
            XCTAssertEqual(todos.first?.status, .proposed)
            XCTAssertNil(todos.first?.sourceFilePath)
            XCTAssertEqual(todos.first?.sourceTimestamp, "00:20")
            let summary = try XCTUnwrap(meeting.summary)
            XCTAssertTrue(summary.contains("**Kim** — "))
            XCTAssertTrue(summary.contains("- **Kim** — Mail de offerte (2026-11-06) [00:10]"))
            XCTAssertTrue(summary.contains("- **Youri** — Plan de demo [00:20]"))
            // "we gaan door" is not in the transcript: the pre-check flags the decision.
            XCTAssertTrue(summary.contains("## Besluiten\n- ⚠︎ We gaan door [00:05]\n"))
            XCTAssertEqual(meeting.actionItems.map(\.verified), [.supported, .unverified], "Youri's 'prima' is too short to count")
            XCTAssertNil(service.warningMessage)
            XCTAssertFalse(summary.contains("```"))
        }
    }

    func testBackgroundSummaryReplacesEarlierProposalsAndKeepsAcceptedTodos() async throws {
        let markdown = notes(actionItems: ["**Kim** — Mail de offerte", "**Youri** — Plan de demo"])
        let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(markdown, json: kimAndYouriJSON)), kimVerdict])
        let service = makeBackgroundService(stub)
        let context = try makeTodoContext()
        let meeting = makeFactsMeeting(speakers: true)
        context.insert(meeting)
        let accepted = TodoItem(text: "Bel de klant", meeting: meeting)
        let stale = TodoItem(text: "Oud voorstel", meeting: meeting)
        stale.status = .proposed
        context.insert(accepted)
        context.insert(stale)
        try context.save()

        try await runInBackground(service, meeting, context)

        let todos = try context.fetch(FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.text)]))
        XCTAssertEqual(todos.map(\.text), ["Bel de klant", "Plan de demo"])
        XCTAssertEqual(todos.map(\.status), [.accepted, .proposed])
    }

    func testFallbackSummaryIsStoredVerbatim() async throws {
        for speakers in [true, false] {
            let markdown = notes(actionItems: ["**Youri** — Mail Kim", "**Kim** — Plan de demo"])
            let stub = StubLLMProvider(outcomes: [.success(markdown), .success("still {bad")])
            let service = makeBackgroundService(stub)
            let context = try makeTodoContext()
            let meeting = makeFactsMeeting(speakers: speakers)
            context.insert(meeting)

            try await runInBackground(service, meeting, context)

            XCTAssertEqual(meeting.summary, markdown, "a markdown-fallback summary is not re-rendered")
            XCTAssertEqual(meeting.actionItems.map(\.task), ["Mail Kim", "Plan de demo"])
            let todos = try context.fetch(FetchDescriptor<TodoItem>())
            XCTAssertEqual(todos.map(\.text), ["Mail Kim"])
            XCTAssertEqual(todos.first?.status, .proposed)
            XCTAssertTrue(try XCTUnwrap(service.warningMessage).contains(SummarizationService.factsFallbackWarning))
        }
    }

    /// Review focus 1: a summary written before Track B parses exactly as it
    /// did, and the meeting carries no structured items.
    func testLegacySummaryRendersUnchanged() throws {
        let meeting = Meeting(title: "Weekly", date: SummaryFixtures.meetingDate, status: .completed)
        meeting.summary = """
        # Samenvatting
        We bespraken de release.

        ## Release
        - **planning:** vrijdag

        ## Besluiten
        - Release gaat vrijdag live

        ## Actiepunten
        - **Youri** — Stuur release notes
        - **?** — Check monitoring

        ## Risico\u{2019}s en blockers
        - Testomgeving kan uitvallen

        ## Opvolging
        - Retro inplannen
        """
        XCTAssertNil(meeting.actionItemsData)
        XCTAssertTrue(meeting.actionItems.isEmpty)

        let parsed = SummaryResponseParser.parse(meeting.summary!)

        XCTAssertEqual(parsed.summary, "# Samenvatting\nWe bespraken de release.")
        XCTAssertEqual(parsed.decisions, ["Release gaat vrijdag live"])
        XCTAssertEqual(parsed.todoTexts, ["**Youri** — Stuur release notes", "**?** — Check monitoring"])
        XCTAssertEqual(parsed.risks, ["Testomgeving kan uitvallen"])
        XCTAssertEqual(parsed.followUps, ["Retro inplannen"])
        XCTAssertEqual(parsed.rawMarkdown, meeting.summary)
        XCTAssertEqual(parsed.todoTexts.map { ActionItemRendering.strippingSuffix(ActionItemOwnership.parse($0).action) },
                       ["Stuur release notes", "Check monitoring"], "legacy to-do texts still match their bullets")
    }

    // MARK: - Verification call (Task 7)

    private func verifyTranscript(speakers: Bool) -> String {
        let lines = [
            ("00:10", "Kim", "Ik mail de offerte vrijdag naar de klant."),
            ("00:20", "Youri", "Prima, dan plan ik de demo voor volgende week."),
            ("00:30", "Kim", "Dan gaan we door met het nieuwe pakket."),
        ]
        return lines.map { "[\($0.0)] " + (speakers ? $0.1 + ": " : "") + $0.2 }.joined(separator: "\n")
    }

    private func makeVerifyMeeting(speakers: Bool) -> Meeting {
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate, status: .completed)
        meeting.transcript = verifyTranscript(speakers: speakers)
        if speakers {
            meeting.speakers = ["Kim", "Youri"].map {
                SpeakerInfo(id: $0, displayName: $0, source: .room, isUser: $0 == "Youri", nameConfirmed: true)
            }
        }
        return meeting
    }

    /// Two quoted items (Kim at 00:10, Youri at 00:20) and one quoted decision at 00:30.
    private func verifyJSON(firstQuote: String = "ik mail de offerte vrijdag", quotes: Bool = true) -> String {
        func q(_ text: String) -> String { quotes ? "\"\(text)\"" : "null" }
        return """
        {"topics":["Offerte"],"decisions":[{"text":"Door met het nieuwe pakket","quote":\(q("dan gaan we door met het nieuwe pakket")),"timestamp":"00:30"}],"action_items":[{"task":"Mail de offerte","owner":"Kim","due":null,"confidence":0.8,"quote":\(q(firstQuote)),"timestamp":"00:10"},{"task":"Plan de demo","owner":"Youri","due":null,"confidence":0.9,"quote":\(q("dan plan ik de demo")),"timestamp":"00:20"}],"open_questions":[],"facts":[]}
        """
    }

    private var verifyNotes: String {
        notes(actionItems: ["**Kim** — Mail de offerte", "**Youri** — Plan de demo"])
    }

    private let verdicts = #"""
    [{"id": "a1", "supported": true, "reason": "Kim zegt het zelf."},
     {"id": "a2", "supported": false, "reason": "Er is geen demo afgesproken."},
     {"id": "d1", "supported": false, "reason": "Er werd niets besloten."}]
    """#

    func testVerificationIsOneCallAfterTheSummary() async throws {
        for speakers in [true, false] {
            let recorder = PhaseRecorder()
            let stub = StubLLMProvider(
                outcomes: [.success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON())), .success(verdicts)],
                onGenerate: { recorder.record() }
            )
            let service = makeBackgroundService(stub)
            recorder.service = service
            let context = try makeTodoContext()
            let meeting = makeVerifyMeeting(speakers: speakers)
            context.insert(meeting)

            try await runInBackground(service, meeting, context)

            XCTAssertEqual(stub.calls.count, 2)
            let prompt = try XCTUnwrap(stub.calls.last?.prompt)
            XCTAssertTrue(prompt.hasPrefix("You are checking meeting notes"))
            XCTAssertTrue(prompt.contains("### a1 (action item)"))
            XCTAssertTrue(prompt.contains("### a2 (action item)"))
            XCTAssertTrue(prompt.contains("### d1 (decision)"))
            XCTAssertTrue(prompt.contains("Meeting date: 2026-11-04"))
            XCTAssertTrue(prompt.contains("\n" + verifyTranscript(speakers: speakers) + "\n"), "the original transcript lines")
            XCTAssertTrue(prompt.hasSuffix(LLMPromptSupport.noThinkSuffix))
            XCTAssertEqual(recorder.phases, [.sending, .verifying])
            XCTAssertEqual(recorder.statuses.last, SummarizationService.verifyingStatus)

            XCTAssertEqual(meeting.actionItems.map(\.verified), [.supported, .unsupported])
            XCTAssertEqual(meeting.actionItems.map(\.verificationReason), ["Kim zegt het zelf.", "Er is geen demo afgesproken."])
            let summary = try XCTUnwrap(meeting.summary)
            XCTAssertTrue(summary.contains("## Besluiten\n- ⚠︎ Door met het nieuwe pakket [00:30]\n"), summary)
            XCTAssertTrue(summary.contains("- **Youri** — Plan de demo [00:20]"))
            let todos = try context.fetch(FetchDescriptor<TodoItem>())
            XCTAssertEqual(todos.map(\.text), ["Plan de demo"])
            XCTAssertEqual(todos.first?.status, .proposed, "an unsupported item is flagged, never auto-accepted")
            XCTAssertNil(service.warningMessage)
        }
    }

    func testInventedQuoteNeverReachesTheVerifierCall() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [
                .success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON(firstQuote: "ik verhuis het kantoor naar Utrecht"))),
                .success(#"[{"id": "a2", "supported": true, "reason": "ja"}, {"id": "d1", "supported": true, "reason": "ja"}]"#),
            ])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 2)
            let prompt = try XCTUnwrap(stub.calls.last?.prompt)
            XCTAssertFalse(prompt.contains("### a1 "))
            XCTAssertFalse(prompt.contains("verhuis"))
            XCTAssertTrue(prompt.contains("### a2 (action item)"))
            XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.unsupported, .supported])
            XCTAssertEqual(outcome.facts.actionItems[0].verificationReason, ActionItemVerifier.quoteNotFoundReason)
            XCTAssertEqual(outcome.facts.decisions.map(\.verified), [.supported])
            XCTAssertTrue(outcome.parsed.rawMarkdown.contains("## Besluiten\n- Door met het nieuwe pakket [00:30]\n"))
        }
    }

    func testNoVerificationCallForMarkdownFallback() async throws {
        // Three markdown items against one JSON item: the guard falls back to
        // the markdown's items (the JSON's quoted decision stays).
        let markdown = notes(actionItems: ["**Kim** — Mail de offerte", "**Youri** — Plan de demo", "**?** — Boek een zaal"])
        for speakers in [true, false] {
            let recorder = PhaseRecorder()
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(markdown, json: verifyJSON()))],
                                       onGenerate: { recorder.record() })
            let service = makeFactsService(stub)
            recorder.service = service

            let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: speakers))

            XCTAssertEqual(outcome.factsSource, .markdownFallback)
            XCTAssertEqual(stub.calls.count, 1)
            XCTAssertEqual(recorder.phases, [.sending])
        }
    }

    func testNoVerificationCallWithoutQuotes() async throws {
        for speakers in [true, false] {
            let recorder = PhaseRecorder()
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON(quotes: false)))],
                                       onGenerate: { recorder.record() })
            let service = makeFactsService(stub)
            recorder.service = service

            let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: speakers))

            XCTAssertEqual(outcome.factsSource, .singlePassJSON)
            XCTAssertEqual(stub.calls.count, 1)
            XCTAssertEqual(recorder.phases, [.sending])
            XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.unverified, .unverified])
            XCTAssertNil(service.warningMessage)
        }
    }

    func testVerifierFailureKeepsSummaryAndWarns() async throws {
        for speakers in [true, false] {
            let stub = StubLLMProvider(outcomes: [
                .success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON(firstQuote: "ik verhuis het kantoor naar Utrecht"))),
                .failure(LLMProviderError.requestFailed(provider: "Stub", kind: .httpStatus(400), message: "bad")),
            ])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 2)
            XCTAssertEqual(outcome.factsSource, .singlePassJSON)
            XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.unsupported, .unverified], "the pre-check verdict stays")
            XCTAssertEqual(outcome.facts.decisions.map(\.verified), [.unverified])
            XCTAssertEqual(service.warningMessage, SummarizationService.verificationFailedWarning)
            XCTAssertNil(service.errorMessage)
            XCTAssertTrue(outcome.parsed.rawMarkdown.contains("- **Youri** — Plan de demo [00:20]"))
        }
    }

    func testUnreadableVerdictsGetOneRepairCall() async throws {
        for speakers in [true, false] {
            let recorder = PhaseRecorder()
            let stub = StubLLMProvider(
                outcomes: [
                    .success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON())),
                    .success(#"[{"id": "a1", "supported": true, "reason": "ja"} {"id": "a2""#),
                    .success(verdicts),
                ],
                onGenerate: { recorder.record() }
            )
            let service = makeFactsService(stub)
            recorder.service = service

            let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 3)
            let repair = try XCTUnwrap(stub.calls.last?.prompt)
            XCTAssertTrue(repair.hasPrefix("The text below was meant to be one JSON array of objects"))
            XCTAssertTrue(repair.contains("Text:\n[{\"id\": \"a1\", \"supported\": true, \"reason\": \"ja\"} {\"id\": \"a2\""))
            XCTAssertEqual(recorder.phases, [.sending, .verifying, .verifying])
            XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.supported, .unsupported])
            XCTAssertNil(service.warningMessage)
        }
    }

    func testUnreadableVerdictsAfterRepairKeepThePrecheckAndWarn() async throws {
        let stub = StubLLMProvider(outcomes: [
            .success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON())),
            .success("All claims are supported."),
            .success("Still no JSON."),
        ])
        let service = makeFactsService(stub)

        let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: true))

        XCTAssertEqual(stub.calls.count, 3)
        XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.unverified, .unverified])
        XCTAssertEqual(outcome.facts.decisions.map(\.verified), [.unverified])
        XCTAssertEqual(service.warningMessage, SummarizationService.verificationFailedWarning)
    }

    func testCancellationDuringTheVerificationCallPropagates() async throws {
        let stub = StubLLMProvider(outcomes: [
            .success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON())),
            .failure(CancellationError()),
        ])
        let service = makeFactsService(stub)

        do {
            _ = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: false))
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
        }
    }

    func testVerificationPromptFitsALocalBudget() async throws {
        // A transcript that fits one local pass, but whose ±60 s windows around
        // three claims add up to more than the 6k budget.
        let filler = String(repeating: "We bespreken de planning. ", count: 5)
        var lines: [String] = []
        for second in 0...60 {
            let label = TranscriptLineFormat.timestampLabel(seconds: Double(second))
            switch second {
            case 10: lines.append("[\(label)] Kim: Ik mail de offerte vrijdag naar de klant.")
            case 20: lines.append("[\(label)] Youri: Prima, dan plan ik de demo voor volgende week.")
            case 30: lines.append("[\(label)] Kim: Dan gaan we door met het nieuwe pakket.")
            default: lines.append("[\(label)] Kim: \(filler)")
            }
        }
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate, status: .completed)
        meeting.transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(LLMPromptSupport.budgetTokens(meeting.transcript!) * 3, LLMPromptSupport.localPromptTokenBudget)
        let stub = StubLLMProvider(
            promptTokenBudget: LLMPromptSupport.localPromptTokenBudget,
            outcomes: [.success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON())), .success(verdicts)]
        )
        let service = makeFactsService(stub)

        let outcome = try await service.summarizeWithFacts(meeting: meeting)

        XCTAssertEqual(stub.calls.count, 2, "one pass, then one verification call")
        let prompt = try XCTUnwrap(stub.calls.last?.prompt)
        XCTAssertTrue(prompt.hasPrefix("You are checking meeting notes"))
        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(prompt), LLMPromptSupport.localPromptTokenBudget,
                                 "the whole call, thinking switch included")
        for id in ["### a1 (action item)", "### a2 (action item)", "### d1 (decision)"] {
            XCTAssertTrue(prompt.contains(id))
        }
        XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.supported, .unsupported])
    }

    // MARK: - Verification review fixes

    /// `count` action items with long tasks, all quoting Kim's 00:10 line.
    private func manyItemsJSON(_ count: Int, taskLength: Int) -> String {
        let items = (1...count).map { n -> [String: Any] in
            ["task": "Taak \(n) " + String(repeating: "x", count: taskLength), "owner": NSNull(), "confidence": 0.8,
             "quote": "ik mail de offerte vrijdag", "timestamp": "00:10"]
        }
        let object: [String: Any] = ["topics": [], "decisions": [], "action_items": items, "open_questions": [], "facts": []]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testClaimsThatDoNotFitTheBudgetStayUnverifiedWithAWarning() async throws {
        for speakers in [true, false] {
            // 40 claims of ~600 chars cannot all fit a 6k-token local budget.
            let everyone = (1...40).map { #"{"id": "a\#($0)", "supported": true, "reason": "ja"}"# }
            let stub = StubLLMProvider(outcomes: [
                .success(SummaryFixtures.withFacts(notes(actionItems: []), json: manyItemsJSON(40, taskLength: 600))),
                .success("[" + everyone.joined(separator: ", ") + "]"),
            ])
            let service = makeFactsService(stub)

            let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 2)
            let prompt = try XCTUnwrap(stub.calls.last?.prompt)
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(prompt), LLMPromptSupport.localPromptTokenBudget)
            let verdicts = outcome.facts.actionItems.map(\.verified)
            let kept = verdicts.prefix { $0 == .supported }.count
            XCTAssertGreaterThan(kept, 0)
            XCTAssertLessThan(kept, 40)
            XCTAssertEqual(Array(verdicts.dropFirst(kept)), Array(repeating: .unverified, count: 40 - kept),
                           "a verdict for a dropped claim is ignored")
            XCTAssertTrue(prompt.contains("### a\(kept) (action item)"))
            XCTAssertFalse(prompt.contains("### a\(kept + 1) (action item)"))
            XCTAssertEqual(service.warningMessage, SummarizationService.verificationIncompleteWarning)
        }
    }

    func testNoVerificationCallWhenNoClaimFitsTheBudget() async throws {
        for speakers in [true, false] {
            let recorder = PhaseRecorder()
            let stub = StubLLMProvider(
                outcomes: [.success(SummaryFixtures.withFacts(notes(actionItems: []), json: manyItemsJSON(1, taskLength: 20_000)))],
                onGenerate: { recorder.record() }
            )
            let service = makeFactsService(stub)
            recorder.service = service

            let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: speakers))

            XCTAssertEqual(stub.calls.count, 1)
            XCTAssertEqual(recorder.phases, [.sending])
            XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.unverified])
            XCTAssertEqual(service.warningMessage, SummarizationService.verificationIncompleteWarning)
        }
    }

    func testTheVerificationRepairFitsTheBudget() async throws {
        let garbage = "[" + String(repeating: #"{"id": "a1", "supported": true} "#, count: 2_000)
        let stub = StubLLMProvider(outcomes: [
            .success(SummaryFixtures.withFacts(verifyNotes, json: verifyJSON())),
            .success(garbage),
            .success(verdicts),
        ])
        let service = makeFactsService(stub)

        let outcome = try await service.summarizeWithFacts(meeting: makeVerifyMeeting(speakers: true))

        XCTAssertEqual(stub.calls.count, 3)
        let repair = try XCTUnwrap(stub.calls.last?.prompt)
        XCTAssertTrue(repair.hasPrefix("The text below was meant to be one JSON array"))
        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(repair), LLMPromptSupport.localPromptTokenBudget)
        XCTAssertEqual(outcome.facts.actionItems.map(\.verified), [.supported, .unsupported])
    }
}

@MainActor
private final class PrepBox {
    var value: String?
    init(value: String?) { self.value = value }
}

@MainActor
private final class ServiceHolder {
    weak var service: SummarizationService?
}

/// Records the service's phase and status line at the start of every stub
/// `generate`, i.e. what the user sees while each call is in flight.
@MainActor
private final class PhaseRecorder {
    weak var service: SummarizationService?
    private(set) var phases: [SummarizationService.SummarizationPhase] = []
    private(set) var statuses: [String] = []

    func record() {
        guard let service else { return }
        phases.append(service.phase)
        statuses.append(service.statusMessage)
    }
}
