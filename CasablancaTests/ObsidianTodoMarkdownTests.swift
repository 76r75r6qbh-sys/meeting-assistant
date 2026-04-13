import Foundation
import XCTest
@testable import Casablanca

final class ObsidianTodoMarkdownTests: XCTestCase {
    func testParseGenericTodoDocumentSplitsOpenAndDoneTasks() throws {
        let markdown = """
        # Casablanca Todos

        ## Open

        - [ ] Follow up with Kim <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->

        ## Done

        - [x] Send summary <!-- casablanca-todo: 660E8400-E29B-41D4-A716-446655440000 -->
        """

        let document = ObsidianTodoMarkdown.parseGenericDocument(markdown)

        XCTAssertEqual(document.openTasks.map(\.text), ["Follow up with Kim"])
        XCTAssertEqual(document.doneTasks.map(\.text), ["Send summary"])
        XCTAssertEqual(document.openTasks.first?.id?.uuidString, "550E8400-E29B-41D4-A716-446655440000")
    }

    func testParseMeetingActionItemsReadsCheckboxesWithoutIds() {
        let markdown = """
        # Prep

        ## Action Items

        - [ ] Bring roadmap slide
        - [x] Mail agenda <!-- casablanca-todo: 770E8400-E29B-41D4-A716-446655440000 -->
        """

        let items = ObsidianTodoMarkdown.parseMeetingActionItems(markdown)

        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0].id)
        XCTAssertEqual(items[0].text, "Bring roadmap slide")
        XCTAssertTrue(items[1].isCompleted)
    }

    func testRenderGenericDocumentCreatesExpectedScaffold() {
        let item = ObsidianTodoMarkdown.TaskLine(
            id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"),
            text: "Follow up with Kim",
            isCompleted: false
        )

        let markdown = ObsidianTodoMarkdown.renderGenericDocument(
            openTasks: [item],
            doneTasks: []
        )

        XCTAssertTrue(markdown.contains("# Casablanca Todos"))
        XCTAssertTrue(markdown.contains("## Open"))
        XCTAssertTrue(markdown.contains("<!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->"))
    }
}
