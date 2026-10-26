import XCTest
@testable import Casablanca

@MainActor
final class SummarizationServiceTests: XCTestCase {
    func testDefaultPromptTemplateIncludesTranscriptAndFreeformNotes() {
        let template = SummarizationService.defaultPromptTemplate

        XCTAssertTrue(template.contains("Transcript:"))
        XCTAssertTrue(template.contains("{{transcript}}"))
        XCTAssertTrue(template.contains("Freeform notes:"))
        XCTAssertTrue(template.contains("{{freeform_notes}}"))
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

    func testRenderPromptSubstitutesTranscriptAndFreeformNotes() {
        let meeting = Meeting(title: "Design Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: SummarizationService.defaultPromptTemplate,
            meeting: meeting,
            transcript: "Transcript body",
            freeformNotes: "Freeform notes body",
            terminologyBlock: ""
        )

        XCTAssertTrue(rendered.contains("Transcript:\nTranscript body"))
        XCTAssertTrue(rendered.contains("Freeform notes:\nFreeform notes body"))
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
        let stub = StubLLMProvider(preferredTimeout: 300, outcomes: [.success("# Summary\nWe ship Friday.")])
        let service = SummarizationService(providerFactory: { stub })

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.timeout, 300)
    }

    /// A local provider keeps the call site's own number, so nothing changes for it.
    func testSummarizeKeepsItsOwnTimeoutForAProviderWithoutAPreference() async throws {
        let stub = StubLLMProvider(preferredTimeout: nil, outcomes: [.success("# Summary\nWe ship Friday.")])
        let service = SummarizationService(providerFactory: { stub })

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

    func testSummarizeSendsALongTranscriptWholeToALargeBudgetProvider() async throws {
        let transcript = makeLongTranscript()
        XCTAssertGreaterThanOrEqual(transcript.count, 147_000)
        let meeting = Meeting(title: "EHDS", date: .now, status: .completed)
        meeting.transcript = transcript
        let stub = StubLLMProvider(promptTokenBudget: 100_000, outcomes: [.success("# Summary\nDone.")])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeDefaults())

        _ = try await service.summarize(meeting: meeting)

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertTrue(try XCTUnwrap(stub.calls.first?.prompt).contains(transcript), "the transcript must arrive whole")
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
        let stub = StubLLMProvider(outcomes: [.success("# Summary\nDone.")])
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
            outcomes: [.failure(StubLLMProvider.transientFailure()), .success("# Summary\nDone.")]
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
        let stub = StubLLMProvider(outcomes: [.success("# Summary\nDone.")], truncatedFlags: [true])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeDefaults())

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(service.warningMessage, "Summary may be truncated: Stub reached its output length limit.")
    }

    // MARK: - Map-reduce

    /// A budget small enough that a ~20k-char transcript needs several parts.
    private let smallBudget = 1_500

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

    /// Canned per-call notes `NOTE-01`, `NOTE-02`, … (zero-padded so no note is a
    /// prefix of another).
    private func numberedNotes(_ count: Int = 60) -> [Result<String, Error>] {
        (1...count).map { .success(String(format: "NOTE-%02d", $0)) }
    }

    private func isMapCall(_ call: StubLLMProvider.Call) -> Bool {
        call.prompt.hasPrefix("You are condensing part")
    }

    private func isMergeCall(_ call: StubLLMProvider.Call) -> Bool {
        call.prompt.hasPrefix("You are merging")
    }

    func testShortTranscriptOnASmallBudgetIsOneCallWithTheWholeTranscript() async throws {
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: [.success("# Summary\nDone.")])
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
            XCTAssertTrue(call.prompt.hasPrefix("You are condensing part \(i + 1) of \(partCount) of a meeting transcript"))
            XCTAssertTrue(call.prompt.contains("Meeting: EHDS. Participants: Unknown. The note-taker is Youri."))
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(call.prompt), smallBudget, "a part must fit the budget")
            XCTAssertEqual(call.maxTokens, LLMPromptSupport.mapOutputTokens)
            XCTAssertTrue(call.prompt.hasSuffix(LLMPromptSupport.noThinkSuffix))
        }
        XCTAssertTrue(mapCalls[0].prompt.contains("(0:00:00–"), "the first part is labelled from its first timestamp")

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
        let note = String(repeating: "- [0:01:00] besproken punt. ", count: 21)  // ~600 chars
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
        let note = String(repeating: "- [0:01:00] besproken punt. ", count: 60)  // ~1,700 chars
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
            outcomes: [.success("NOTE-01"), .success("<think>Nothing to note.</think>"), .success("NOTE-03")]
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

    func testTruncatedPartNotesSetTheOutputLimitWarning() async throws {
        let stub = StubLLMProvider(promptTokenBudget: smallBudget, outcomes: numberedNotes(), truncatedFlags: [true, false])
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try await service.summarize(meeting: makeMeeting(transcript: makeLongTranscript(chars: 20_000)))

        XCTAssertEqual(service.warningMessage, "Summary may be truncated: Stub reached its output length limit.")
    }

    func testAFailedPartFailsTheSummaryAndRetryReusesTheCondensedParts() async throws {
        let transcript = makeLongTranscript(chars: 20_000)
        let meeting = makeMeeting(transcript: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [
                .success("NOTE-01"), .success("NOTE-02"),
                .failure(StubLLMProvider.transientFailure()), .failure(StubLLMProvider.transientFailure()),
                .success("NOTE-LATER")
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
        XCTAssertTrue(try XCTUnwrap(retryCalls.first).prompt.hasPrefix("You are condensing part 3 of"))
        XCTAssertFalse(retryCalls.contains { $0.prompt.hasPrefix("You are condensing part 1 of") || $0.prompt.hasPrefix("You are condensing part 2 of") })
        let reduce = try XCTUnwrap(retryCalls.last).prompt
        XCTAssertTrue(reduce.contains("NOTE-01") && reduce.contains("NOTE-02"), "cached parts reach the reduce")

        // Success cleared the meeting's parts: summarizing again condenses afresh.
        let before = stub.calls.count
        _ = try await service.summarize(meeting: meeting)
        XCTAssertTrue(stub.calls[before].prompt.hasPrefix("You are condensing part 1 of"))
    }

    func testTheCacheIsReplacedWhenAnotherMeetingIsSummarized() async throws {
        let transcript = makeLongTranscript(chars: 20_000)
        let first = makeMeeting(transcript: transcript)
        let stub = StubLLMProvider(
            promptTokenBudget: smallBudget,
            outcomes: [.success("NOTE-01"), .failure(LLMProviderError.requestFailed(provider: "Stub", kind: .httpStatus(400), message: "bad")), .success("NOTE")]
        )
        let service = SummarizationService(providerFactory: { stub }, userDefaults: makeMapReduceDefaults())

        _ = try? await service.summarize(meeting: first)
        XCTAssertEqual(stub.calls.count, 2)

        _ = try await service.summarize(meeting: makeMeeting(transcript: transcript))
        let before = stub.calls.count
        _ = try await service.summarize(meeting: first)
        XCTAssertTrue(stub.calls[before].prompt.hasPrefix("You are condensing part 1 of"), "the first meeting's parts were dropped")
    }

    func testPhasesProgressThroughEachPartThenSending() async throws {
        let recorder = PhaseRecorder()
        let stub = StubLLMProvider(
            displayName: "Ollama",
            promptTokenBudget: smallBudget,
            outcomes: [.success("NOTE-01"), .failure(StubLLMProvider.transientFailure())] + numberedNotes(),
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
