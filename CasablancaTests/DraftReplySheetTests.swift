import XCTest
@testable import Casablanca

/// The logic around the draft sheet: which to-dos offer "Draft reply", and the
/// prompt "Continue in Claude Code" hands over.
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
}
