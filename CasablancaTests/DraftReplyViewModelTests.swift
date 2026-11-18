import XCTest
@testable import Casablanca

/// A drafter whose calls suspend until the test resumes them, so each test
/// controls exactly when (and whether) a result arrives. No real `claude` run.
@MainActor
private final class FakeDrafter: DraftReplyDrafting {
    enum Call: Equatable {
        case draft(DraftReplyContext)
        case revise(draft: String, steer: String, context: DraftReplyContext)
    }

    private(set) var calls: [Call] = []
    /// One entry per call that has been resumed: whether its task was cancelled
    /// by the time the result came back.
    private(set) var observedCancellation: [Bool] = []
    private var pending: [CheckedContinuation<DraftReplyOutput, Error>] = []

    var pendingCount: Int { pending.count }

    func draft(_ context: DraftReplyContext) async throws -> DraftReplyOutput {
        calls.append(.draft(context))
        return try await suspend()
    }

    func revise(draft: String, steer: String, context: DraftReplyContext) async throws -> DraftReplyOutput {
        calls.append(.revise(draft: draft, steer: steer, context: context))
        return try await suspend()
    }

    /// Resumes the oldest suspended call.
    func resume(with result: Result<DraftReplyOutput, Error>) {
        precondition(!pending.isEmpty, "no call is waiting")
        pending.removeFirst().resume(with: result)
    }

    private func suspend() async throws -> DraftReplyOutput {
        let output = try await withCheckedThrowingContinuation { pending.append($0) }
        // Returns the result even when cancelled: the view model must drop it.
        observedCancellation.append(Task.isCancelled)
        return output
    }
}

@MainActor
final class DraftReplyViewModelTests: XCTestCase {
    private static func context(sourceRef: String? = nil) -> DraftReplyContext {
        DraftReplyContext(
            todoText: "Kim antwoorden over de BgZ-planning",
            owner: "Youri",
            dueDate: nil,
            sourceRef: sourceRef,
            meetingTitle: nil,
            meetingDate: nil,
            meetingSummary: nil,
            transcriptExcerpt: nil
        )
    }

    private var fake: FakeDrafter!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeDrafter()
    }

    /// Lets the view model's task run until the drafter suspends.
    private func waitForPendingCall(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 where fake.pendingCount == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThan(fake.pendingCount, 0, "the drafter was never called", file: file, line: line)
    }

    /// Starts a draft and lets it arrive with `body`.
    private func readyModel(body: String = "Hoi Kim,", channel: String? = "email") async -> DraftReplyViewModel {
        let model = DraftReplyViewModel(context: Self.context(), drafter: fake)
        model.start()
        await waitForPendingCall()
        fake.resume(with: .success(DraftReplyOutput(channel: channel, body: body)))
        await model.inFlight?.value
        return model
    }

    // MARK: - Draft

    func testStartGoesGeneratingThenReady() async {
        let context = Self.context()
        let model = DraftReplyViewModel(context: context, drafter: fake)

        model.start()
        XCTAssertEqual(model.phase, .generating("Writing the draft…"))
        await waitForPendingCall()
        XCTAssertEqual(fake.calls, [.draft(context)])

        fake.resume(with: .success(DraftReplyOutput(channel: "Teams", body: "Hoi Kim,\n\nGroet, Youri")))
        await model.inFlight?.value

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draftText, "Hoi Kim,\n\nGroet, Youri")
        XCTAssertEqual(model.channel, "Teams")
        XCTAssertFalse(model.isEdited)
    }

    func testStartWithSourceSaysItIsReadingTheSource() async {
        let model = DraftReplyViewModel(context: Self.context(sourceRef: "jira:IO-1234"), drafter: fake)

        model.start()
        XCTAssertEqual(model.phase, .generating("Reading the source…"))

        await waitForPendingCall()
        fake.resume(with: .success(DraftReplyOutput(channel: nil, body: "x")))
        await model.inFlight?.value
    }

    func testFailureShowsMessage() async {
        let model = DraftReplyViewModel(context: Self.context(), drafter: fake)

        model.start()
        await waitForPendingCall()
        fake.resume(with: .failure(LLMProviderError.requestFailed(
            provider: "Claude Code", kind: .backendError, message: "Not logged in · Please run /login"
        )))
        await model.inFlight?.value

        guard case .failed(let message) = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("Not logged in"), message)
        XCTAssertEqual(model.draftText, "")
    }

    func testFailureWithoutLocalizedErrorUsesLocalizedDescription() async {
        struct Plain: Error {}
        let model = DraftReplyViewModel(context: Self.context(), drafter: fake)

        model.start()
        await waitForPendingCall()
        fake.resume(with: .failure(Plain()))
        await model.inFlight?.value

        XCTAssertEqual(model.phase, .failed(Plain().localizedDescription))
    }

    func testRetryAfterFailureStartsAgain() async {
        let model = DraftReplyViewModel(context: Self.context(), drafter: fake)
        model.start()
        await waitForPendingCall()
        fake.resume(with: .failure(LLMProviderError.emptyResponse(provider: "Claude Code")))
        await model.inFlight?.value

        model.start()
        await waitForPendingCall()
        fake.resume(with: .success(DraftReplyOutput(channel: nil, body: "Hoi Kim,")))
        await model.inFlight?.value

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draftText, "Hoi Kim,")
        XCTAssertEqual(fake.calls.count, 2)
    }

    // MARK: - Cancel

    func testCancelDuringGenerationIgnoresLateResult() async {
        let model = DraftReplyViewModel(context: Self.context(), drafter: fake)
        model.start()
        await waitForPendingCall()

        model.cancel()
        fake.resume(with: .success(DraftReplyOutput(channel: "email", body: "Too late")))
        await model.inFlight?.value

        XCTAssertEqual(fake.observedCancellation, [true], "the drafter's task was not cancelled")
        XCTAssertNotEqual(model.phase, .ready)
        XCTAssertEqual(model.draftText, "")
        XCTAssertNil(model.channel)
    }

    func testCancelDuringRevisionKeepsTheDraft() async {
        let model = await readyModel(body: "Hoi Kim,")
        model.steer = "korter"
        model.revise()
        await waitForPendingCall()

        model.cancel()
        fake.resume(with: .success(DraftReplyOutput(channel: nil, body: "Too late")))
        await model.inFlight?.value

        XCTAssertEqual(fake.observedCancellation.last, true)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draftText, "Hoi Kim,")
        XCTAssertEqual(model.steer, "korter")
    }

    func testStartOverDropsTheResultOfTheEarlierRun() async {
        let model = DraftReplyViewModel(context: Self.context(), drafter: fake)
        model.start()
        await waitForPendingCall()
        let first = model.inFlight

        model.startOver()
        for _ in 0..<100 where fake.pendingCount < 2 { await Task.yield() }
        XCTAssertEqual(fake.pendingCount, 2)

        fake.resume(with: .success(DraftReplyOutput(channel: "email", body: "Old")))
        await first?.value
        XCTAssertEqual(model.phase, .generating("Writing the draft…"))
        XCTAssertEqual(model.draftText, "")

        fake.resume(with: .success(DraftReplyOutput(channel: "Teams", body: "New")))
        await model.inFlight?.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draftText, "New")
        XCTAssertEqual(model.channel, "Teams")
    }

    // MARK: - Revise

    func testReviseSendsEditedDraftAndSteer() async {
        let context = Self.context()
        let model = DraftReplyViewModel(context: context, drafter: fake)
        model.start()
        await waitForPendingCall()
        fake.resume(with: .success(DraftReplyOutput(channel: "email", body: "Hoi Kim,")))
        await model.inFlight?.value

        model.draftText = "Hoi Kim, dank je."
        model.steer = "korter"
        XCTAssertTrue(model.isEdited)
        model.revise()
        XCTAssertEqual(model.phase, .generating("Revising…"))
        await waitForPendingCall()

        XCTAssertEqual(fake.calls.last, .revise(draft: "Hoi Kim, dank je.", steer: "korter", context: context))

        fake.resume(with: .success(DraftReplyOutput(channel: nil, body: "Dank, Kim.")))
        await model.inFlight?.value

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draftText, "Dank, Kim.")
        XCTAssertEqual(model.steer, "")
        XCTAssertFalse(model.isEdited)
        XCTAssertEqual(model.channel, "email", "a revision without a channel line keeps the channel")
    }

    func testRevisionFailureShowsMessage() async {
        let model = await readyModel()
        model.steer = "korter"
        model.revise()
        await waitForPendingCall()
        fake.resume(with: .failure(LLMProviderError.requestFailed(
            provider: "Claude Code", kind: .backendError, message: "Rate limited"
        )))
        await model.inFlight?.value

        XCTAssertEqual(model.phase, .failed("Rate limited"))
    }

    func testCanReviseRequiresSteerOrEdit() async {
        let model = DraftReplyViewModel(context: Self.context(), drafter: fake)
        model.steer = "korter"
        XCTAssertFalse(model.canRevise, "nothing to revise before a draft arrived")
        model.steer = ""

        model.start()
        await waitForPendingCall()
        model.steer = "korter"
        XCTAssertFalse(model.canRevise, "not while generating")
        model.steer = ""
        fake.resume(with: .success(DraftReplyOutput(channel: nil, body: "Hoi Kim,")))
        await model.inFlight?.value

        XCTAssertFalse(model.canRevise, "a fresh draft with no steer")
        model.steer = "  \n "
        XCTAssertFalse(model.canRevise, "a whitespace-only steer")
        model.steer = "korter"
        XCTAssertTrue(model.canRevise)

        model.steer = ""
        model.draftText = "Hoi Kim!"
        XCTAssertTrue(model.isEdited)
        XCTAssertTrue(model.canRevise, "an edit alone is enough")
    }

    func testReviseIsIgnoredWhenItCannotRevise() async {
        let model = await readyModel()
        model.revise()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(fake.calls.count, 1)
    }

    // MARK: - isEdited

    func testResultsDoNotCountAsEdits() async {
        let model = await readyModel(body: "Hoi Kim,")
        XCTAssertFalse(model.isEdited)

        model.draftText = "Hoi Kim"
        XCTAssertTrue(model.isEdited)

        model.startOver()
        XCTAssertFalse(model.isEdited, "starting over discards the edit")
        XCTAssertEqual(model.draftText, "")
        await waitForPendingCall()
        fake.resume(with: .success(DraftReplyOutput(channel: nil, body: "Nieuw")))
        await model.inFlight?.value
        XCTAssertFalse(model.isEdited)
    }
}
