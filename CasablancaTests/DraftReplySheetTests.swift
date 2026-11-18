import SwiftData
import XCTest
@testable import Casablanca

/// Never called: the request tests only check what the view model was built from.
private struct UnusedDrafter: DraftReplyDrafting {
    func draft(_ context: DraftReplyContext) async throws -> DraftReplyOutput {
        XCTFail("drafted"); throw CancellationError()
    }

    func revise(draft: String, steer: String, context: DraftReplyContext) async throws -> DraftReplyOutput {
        XCTFail("revised"); throw CancellationError()
    }
}

/// The logic around the draft sheet: which to-dos offer "Draft reply", the
/// snapshot the sheet is built from, and the prompt "Continue in Claude Code"
/// hands over.
final class DraftReplySheetTests: XCTestCase {
    private let context = DraftReplyContext(
        todoText: "Reply to Kim",
        owner: nil, dueDate: nil,
        sourceRef: "jira:IO-1234",
        meetingTitle: nil, meetingDate: nil, meetingSummary: nil, transcriptExcerpt: nil
    )

    @MainActor
    func testOnlyOpenAcceptedTodosOfferADraftReply() {
        let todo = TodoItem(text: "Reply to Kim")
        XCTAssertTrue(TodoRowPresentation(todo: todo).canDraftReply)

        todo.isCompleted = true
        XCTAssertFalse(TodoRowPresentation(todo: todo).canDraftReply, "done")

        todo.isCompleted = false
        todo.status = .proposed
        XCTAssertFalse(TodoRowPresentation(todo: todo).canDraftReply, "in review")

        todo.status = .rejected
        XCTAssertFalse(TodoRowPresentation(todo: todo).canDraftReply, "rejected")
    }

    func testContinuationWithoutADraftIsTheInitialPrompt() {
        XCTAssertEqual(
            DraftReplyPrompt.continuation(draft: "  \n", steer: "", context: context),
            DraftReplyPrompt.initial(context)
        )
    }

    func testContinuationWithADraftIsTheRevisionPrompt() {
        XCTAssertEqual(
            DraftReplyPrompt.continuation(draft: "Hoi Kim", steer: "shorter", context: context),
            DraftReplyPrompt.revision(draft: "Hoi Kim", steer: "shorter", context: context)
        )
    }

    // MARK: - Request snapshot

    /// The sheet is built from a value taken once at tap time: changing the
    /// to-do or its meeting afterwards changes nothing the sheet shows or drafts.
    @MainActor
    func testRequestSnapshotsTheTodoOnce() throws {
        let (container, todo, meeting) = try Self.makeTodo()
        let request = DraftReplyRequest(todo: todo, drafter: UnusedDrafter())
        let context = request.viewModel.context

        XCTAssertEqual(request.todoText, "Reply to Kim")
        XCTAssertEqual(request.meetingID, meeting.id)
        XCTAssertEqual(request.sourceLink, TodoSourceLink("jira:IO-1234"))
        XCTAssertNotNil(request.meetingSubtitle)
        XCTAssertEqual(context.todoText, "Reply to Kim")
        XCTAssertEqual(context.meetingSummary, "Summary text")
        XCTAssertEqual(context.transcriptExcerpt, "[00:01] Kim: can you send it?")

        todo.text = "Changed"
        todo.sourceRef = nil
        meeting.title = "Other"
        meeting.summary = "Other summary"
        meeting.transcript = "other"

        XCTAssertEqual(request.todoText, "Reply to Kim")
        XCTAssertEqual(request.sourceLink, TodoSourceLink("jira:IO-1234"))
        XCTAssertEqual(request.viewModel.context, context)
        withExtendedLifetime(container) {}
    }

    /// A rebuild of the sheet (what `.sheet(item:)` does on every parent render)
    /// reuses the request's one view model and reads nothing from the to-do, so
    /// a to-do deleted by a sync while the sheet is open is never read again.
    @MainActor
    func testSheetRebuildAfterTheTodoIsDeletedUsesTheSnapshot() throws {
        let (container, todo, _) = try Self.makeTodo()
        let request = DraftReplyRequest(todo: todo, drafter: UnusedDrafter())
        let viewModel = request.viewModel

        container.mainContext.delete(todo)
        try container.mainContext.save()

        // Every value the sheet's init reads comes from the request.
        _ = DraftReplySheet(request: request, toastCenter: ToastCenter(), onOpenMeeting: {}) { _ in }
        XCTAssertTrue(request.viewModel === viewModel)
        XCTAssertEqual(request.todoText, "Reply to Kim")
        XCTAssertEqual(viewModel.context.todoText, "Reply to Kim")
    }

    // MARK: - Fixtures

    /// An in-memory store, so the to-do/meeting relationship behaves as in the
    /// app. The container is returned so it outlives the models.
    @MainActor
    private static func makeTodo() throws -> (ModelContainer, TodoItem, Meeting) {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let meeting = Meeting(title: "Refinement", date: Date())
        meeting.summary = "Summary text"
        meeting.transcript = "[00:01] Kim: can you send it?"
        container.mainContext.insert(meeting)
        let todo = TodoItem(text: "Reply to Kim", meeting: meeting)
        todo.sourceRef = "jira:IO-1234"
        container.mainContext.insert(todo)
        return (container, todo, meeting)
    }
}
