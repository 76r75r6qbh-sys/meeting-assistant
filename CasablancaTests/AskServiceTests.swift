import Foundation
import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class AskServiceTests: XCTestCase {

    // MARK: - Fixtures

    private var calendar: Calendar { .current }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    /// Meeting A: BgZ exchange. Meeting B: partner onboarding, tagged "partner".
    private func makeMeetings() -> (a: Meeting, b: Meeting) {
        let a = Meeting(title: "Refinement Team Link", date: date(2026, 11, 3), participants: ["Kim"], status: .completed)
        a.transcript = """
        [00:10] Kim: We besluiten de BgZ uitwisseling via Wegiz te bouwen.
        [00:40] Youri: Akkoord, de BgZ gaat in sprint drie.
        """
        let b = Meeting(title: "Partner overleg", date: date(2026, 11, 4), participants: ["Arriejanne"], status: .completed)
        b.transcript = """
        [00:05] Arriejanne: De partner wil de BgZ koppeling ook gebruiken.
        [00:20] Kim: Onboarding van de partner start in december.
        """
        b.tags = ["partner"]
        return (a, b)
    }

    private func snapshots(_ meetings: [Meeting]) -> [AskMeetingSnapshot] {
        meetings.map { AskMeetingSnapshot(meeting: $0) }
    }

    private func source(for meeting: Meeting, time: String) -> String {
        "[\(AskCitationFormat.citationTitle(meeting.title)), \(AskCitationFormat.dateLabel(meeting.date)), \(time)]"
    }

    private func makeService(
        _ meetings: [Meeting],
        stub: StubLLMProvider,
        retryPolicy: LLMRetryPolicy = LLMRetryPolicy(maxAttempts: 1, baseDelay: 0, sleep: { _ in }),
        thinking: Bool = true,
        loaderCalls: LoaderCounter? = nil
    ) -> AskService {
        let snaps = snapshots(meetings)
        return AskService(
            snapshotLoader: {
                loaderCalls?.count += 1
                return snaps
            },
            providerFactory: { stub },
            retryPolicy: retryPolicy,
            thinkingEnabled: { thinking }
        )
    }

    @MainActor
    private final class LoaderCounter {
        var count = 0
    }

    private func waitForAnswer(_ service: AskService) async throws {
        for _ in 0..<2_000 {
            if !service.isAnswering && !service.isIndexing { return }
            await Task.yield()
        }
        XCTFail("the answer never completed")
    }

    private func ask(_ service: AskService, _ question: String, filter: AskFilter = .none) async throws {
        let task = try XCTUnwrap(service.ask(question, filter: filter))
        await task.value
        try await waitForAnswer(service)
    }

    // MARK: - Retrieval and prompt

    func testAskSendsRetrievedSourcesAndQuestion() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("Ja.")])
        let service = makeService([a, b], stub: stub)

        try await ask(service, "Wegiz besluiten")

        XCTAssertEqual(stub.calls.count, 1)
        let prompt = try XCTUnwrap(stub.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("Cite as: " + source(for: a, time: "00:10")), prompt)
        XCTAssertTrue(prompt.contains("## Question\nWegiz besluiten"))
        XCTAssertFalse(prompt.contains(b.title))
        XCTAssertEqual(service.answer?.question, "Wegiz besluiten")
        XCTAssertEqual(service.answer?.text, "Ja.")
    }

    func testFilterRestrictsSources() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("Ja.")])
        let service = makeService([a, b], stub: stub)

        try await ask(service, "BgZ", filter: AskFilter(tag: "partner"))

        let prompt = try XCTUnwrap(stub.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("Cite as: [\(b.title)"))
        XCTAssertFalse(prompt.contains("Cite as: [\(a.title)"))
        XCTAssertTrue(service.answer?.sources.allSatisfy { $0.meetingID == b.id } ?? false)
        XCTAssertFalse(service.answer?.sources.isEmpty ?? true)
    }

    func testNoMatchSkipsLLM() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("should not be used")])
        let service = makeService([a, b], stub: stub)

        try await ask(service, "zeppelin xylofoon")

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertEqual(service.answer?.text, AskService.noMatchText)
        XCTAssertEqual(service.answer?.text, "No meeting content matches this question and filter.")
        XCTAssertEqual(service.answer?.segments, [.text("No meeting content matches this question and filter.")])
        XCTAssertEqual(service.answer?.sources, [])
    }

    func testUsesProviderBudgetAndTimeout() async throws {
        // Many meetings matching the question, so the budget is what limits the prompt.
        let meetings = (1...30).map { n -> Meeting in
            let m = Meeting(title: "BgZ overleg \(n)", date: date(2026, 10, n), status: .completed)
            m.transcript = (0..<40).map { i in
                String(format: "[%02d:%02d] Kim: ", i, n) + "de BgZ uitwisseling en de Wegiz planning punt \(i) voor overleg \(n)"
            }.joined(separator: "\n")
            return m
        }
        let stub = StubLLMProvider(preferredTimeout: 600, promptTokenBudget: 1_500, outcomes: [.success("Ja.")])
        let service = makeService(meetings, stub: stub, thinking: false)

        try await ask(service, "BgZ Wegiz")

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(call.prompt), 1_500)
        XCTAssertEqual(call.timeout, 600)
    }

    func testAnswerCitationsAreResolved() async throws {
        let (a, b) = makeMeetings()
        let reply = "Ja \(source(for: a, time: "00:10"))."
        let stub = StubLLMProvider(outcomes: [.success(reply)])
        let service = makeService([a, b], stub: stub)

        try await ask(service, "Wegiz besluiten")

        let segments = try XCTUnwrap(service.answer?.segments)
        let targets = segments.flatMap { segment -> [AskCitationTarget] in
            if case let .citations(_, list) = segment { return list.compactMap(\.target) }
            return []
        }
        XCTAssertEqual(targets, [AskCitationTarget(meetingID: a.id, seconds: 10)])
    }

    func testSingleTurnReplacesAnswer() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("Eerste."), .success("Tweede.")])
        let service = makeService([a, b], stub: stub)

        try await ask(service, "Wegiz besluiten")
        try await ask(service, "partner onboarding")

        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertFalse(stub.calls[1].prompt.contains("Wegiz besluiten"))
        XCTAssertEqual(service.answer?.question, "partner onboarding")
        XCTAssertEqual(service.answer?.text, "Tweede.")
    }

    func testThinkingOffAppendsNoThink() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("Ja.")])
        let service = makeService([a, b], stub: stub, thinking: false)

        try await ask(service, "Wegiz")

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.prompt.hasSuffix("/no_think"))
        XCTAssertEqual(call.maxTokens, LLMPromptSupport.cappedOutputTokens)
    }

    func testThinkingOnSendsNoCap() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("Ja.")])
        let service = makeService([a, b], stub: stub, thinking: true)

        try await ask(service, "Wegiz")

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertFalse(call.prompt.hasSuffix("/no_think"))
        XCTAssertNil(call.maxTokens)
        XCTAssertNil(call.temperature)
    }

    func testReasoningTagsStripped() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("<think>x</think># Antwoord\nJa")])
        let service = makeService([a, b], stub: stub)

        try await ask(service, "Wegiz")

        XCTAssertEqual(service.answer?.text, "# Antwoord\nJa")
    }

    func testEmptyModelOutputSaysSo() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(displayName: "Ollama", outcomes: [.success("<think>only thoughts</think>  ")])
        let service = makeService([a, b], stub: stub)

        try await ask(service, "Wegiz")

        XCTAssertEqual(service.answer?.text, "Ollama returned an empty answer.")
    }

    // MARK: - Lazy index

    func testIndexIsLazyAndInvalidates() async throws {
        let (a, b) = makeMeetings()
        let counter = LoaderCounter()
        let stub = StubLLMProvider(outcomes: [.success("Ja.")])
        let service = makeService([a, b], stub: stub, loaderCalls: counter)
        XCTAssertEqual(counter.count, 0)

        try await ask(service, "Wegiz")
        XCTAssertEqual(counter.count, 1)

        try await ask(service, "partner")
        XCTAssertEqual(counter.count, 1)

        service.invalidateIndex()
        try await ask(service, "Wegiz")
        XCTAssertEqual(counter.count, 2)
    }

    func testPrepareIndexPublishesFilterOptions() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider()
        let service = makeService([a, b], stub: stub)

        await service.prepareIndex().value

        XCTAssertFalse(service.isIndexing)
        XCTAssertEqual(service.filterOptions.participants, ["Arriejanne", "Kim"])
        XCTAssertEqual(service.filterOptions.tags, ["partner"])
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testLoaderErrorSurfacesWithoutLLMCall() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "store unavailable" } }
        let stub = StubLLMProvider()
        let service = AskService(
            snapshotLoader: { throw Boom() },
            providerFactory: { stub },
            thinkingEnabled: { true }
        )

        try await ask(service, "Wegiz")

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertEqual(service.errorMessage, "store unavailable")
        XCTAssertNil(service.answer)
        XCTAssertFalse(service.isAnswering)
    }

    /// Several saves in a burst mark the index stale once, after the debounce.
    func testStoreSavesInvalidateDebounced() async throws {
        let (a, b) = makeMeetings()
        let counter = LoaderCounter()
        let stub = StubLLMProvider()
        let service = makeService([a, b], stub: stub, loaderCalls: counter)
        service.observeStoreChanges(debounce: .milliseconds(30))

        await service.prepareIndex().value
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(service.isIndexFresh)

        for _ in 0..<5 {
            NotificationCenter.default.post(name: ModelContext.didSave, object: nil)
        }
        XCTAssertTrue(service.isIndexFresh, "invalidation waits for the debounce")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(service.isIndexFresh)

        await service.prepareIndex().value
        XCTAssertEqual(counter.count, 2, "one rebuild for the whole burst")
    }

    // MARK: - Errors, retry, cancellation

    func testRetryStatusAndErrorSurface() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [
            .failure(StubLLMProvider.transientFailure()),
            .failure(StubLLMProvider.transientFailure()),
            .failure(StubLLMProvider.transientFailure()),
        ])
        let service = makeService(
            [a, b], stub: stub,
            retryPolicy: LLMRetryPolicy(maxAttempts: 3, baseDelay: 0, sleep: { _ in })
        )

        try await ask(service, "Wegiz")

        XCTAssertEqual(stub.calls.count, 3)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isAnswering)
    }

    func testRetryStatusMessageWhileRetrying() async throws {
        let (a, b) = makeMeetings()
        let observer = StatusObserver()
        let stub = StubLLMProvider(
            displayName: "Claude Code",
            outcomes: [.failure(StubLLMProvider.transientFailure()), .success("Ja.")],
            onGenerate: { [observer] in observer.record() }
        )
        let service = makeService(
            [a, b], stub: stub,
            retryPolicy: LLMRetryPolicy(maxAttempts: 3, baseDelay: 0, sleep: { _ in })
        )
        observer.service = service

        try await ask(service, "Wegiz")

        XCTAssertEqual(observer.statuses, [nil, "Claude Code request failed, retrying (2/3)…"])
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.answer?.text, "Ja.")
    }

    @MainActor
    private final class StatusObserver {
        weak var service: AskService?
        var statuses: [String?] = []
        func record() { statuses.append(service?.statusMessage) }
    }

    func testCancelDropsTheAnswer() async throws {
        let (a, b) = makeMeetings()
        let holder = ServiceHolder()
        let stub = StubLLMProvider(
            outcomes: [.success("te laat")],
            onGenerate: { [holder] in holder.service?.cancel() }
        )
        let service = makeService([a, b], stub: stub)
        holder.service = service

        let task = try XCTUnwrap(service.ask("Wegiz", filter: .none))
        await task.value

        XCTAssertNil(service.answer)
        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isAnswering)
        XCTAssertTrue(task.isCancelled)
    }

    @MainActor
    private final class ServiceHolder {
        weak var service: AskService?
    }

    func testEmptyQuestionIsIgnored() {
        let stub = StubLLMProvider()
        let service = makeService([], stub: stub)
        XCTAssertNil(service.ask("  ", filter: .none))
        XCTAssertFalse(service.isAnswering)
    }

    func testSecondAskWhileAnsweringIsIgnored() async throws {
        let (a, b) = makeMeetings()
        let stub = StubLLMProvider(outcomes: [.success("Ja.")])
        let service = makeService([a, b], stub: stub)

        let first = try XCTUnwrap(service.ask("Wegiz", filter: .none))
        XCTAssertNil(service.ask("partner", filter: .none))
        await first.value
        XCTAssertEqual(stub.calls.count, 1)
    }

    // MARK: - Background paged loader

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Seeded (and saved) on the main actor; read on a background context in
    /// pages of 2. The newest page holds only skipped rows (an upcoming and an
    /// empty meeting), so paging by snapshot count would stop too early.
    func testPagedLoaderPagesByFetchedRowsOffMain() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let upcoming = Meeting(title: "Upcoming", date: date(2026, 11, 20), status: .upcoming)
        upcoming.summary = "Agenda"
        let empty = Meeting(title: "Leeg", date: date(2026, 11, 19), status: .completed)
        context.insert(upcoming)
        context.insert(empty)
        var expected: [UUID] = []
        for day in 1...5 {
            let m = Meeting(title: "Dag \(day)", date: date(2026, 11, 10 - day), status: .completed)
            m.transcript = "[00:01] dag \(day)"
            context.insert(m)
            expected.append(m.id)
        }
        try context.save()

        let loader = AskService.pagedSnapshotLoader(container: container, pageSize: 2)
        let snapshots = try await Task.detached { try await loader() }.value

        XCTAssertEqual(snapshots.map(\.id), expected)
        XCTAssertEqual(Set(snapshots.map(\.id)).count, snapshots.count)
    }

    func testBackgroundLoaderServiceAnswers() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (a, b) = makeMeetings()
        context.insert(a)
        context.insert(b)
        try context.save()

        let stub = StubLLMProvider(outcomes: [.success("Ja.")])
        let service = AskService(
            container: container,
            isPendingDeletion: { [bID = b.id] in $0 == bID },
            providerFactory: { stub },
            retryPolicy: LLMRetryPolicy(maxAttempts: 1, baseDelay: 0, sleep: { _ in }),
            thinkingEnabled: { true },
            observesStoreChanges: false
        )

        try await ask(service, "BgZ")

        let prompt = try XCTUnwrap(stub.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("Cite as: [\(a.title)"))
        XCTAssertFalse(prompt.contains("Cite as: [\(b.title)"), "pending-deletion meetings are excluded")
        XCTAssertEqual(service.filterOptions.participants, ["Kim"])
    }
}
