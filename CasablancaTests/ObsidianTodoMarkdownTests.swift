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

    // MARK: - In-place edits preserve everything else

    private static let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    /// A realistic Prep file: frontmatter, other sections, hand-written text,
    /// nested sub-bullets, non-standard tasks and an `###` sub-heading under
    /// `## Action Items`, followed by an H1 that closes the section.
    private static let prep = """
    ---
    date: 2025-04-12
    ---
    # Weekly Sync - Prep

    ## Agenda

    - Roadmap
      - Q3 items

    ## Action Items

    Context line written by hand.

    - [ ] Bring roadmap slide <!-- casablanca-todo: AAAAAAAA-0000-0000-0000-000000000001 -->
      - sub-bullet detail
      - [ ] nested sub-task
    - [/] In progress thing
    * [ ] Star task
    - [x] Mail agenda <!-- casablanca-todo: BBBBBBBB-0000-0000-0000-000000000002 -->
        wrapped continuation

    ### Follow-ups

    Free text under h3.

    # Appendix

    Trailing text.

    """

    func testSettingTaskCompletionFlipsOnlyThatCheckbox() throws {
        let updated = try XCTUnwrap(ObsidianTodoMarkdown.settingTaskCompletion(Self.prep, id: Self.idA, isCompleted: true))
        XCTAssertEqual(
            updated,
            Self.prep.replacingOccurrences(of: "- [ ] Bring roadmap slide", with: "- [x] Bring roadmap slide")
        )
        let reopened = try XCTUnwrap(ObsidianTodoMarkdown.settingTaskCompletion(updated, id: Self.idA, isCompleted: false))
        XCTAssertEqual(reopened, Self.prep)
    }

    func testSettingTaskCompletionForUnknownIDReturnsNil() {
        XCTAssertNil(ObsidianTodoMarkdown.settingTaskCompletion(Self.prep, id: UUID(), isCompleted: true))
    }

    func testRemovingTaskDropsOnlyThatLine() throws {
        let updated = try XCTUnwrap(ObsidianTodoMarkdown.removingTask(Self.prep, id: Self.idB))
        XCTAssertEqual(
            updated,
            Self.prep.replacingOccurrences(
                of: "- [x] Mail agenda <!-- casablanca-todo: BBBBBBBB-0000-0000-0000-000000000002 -->\n",
                with: ""
            )
        )
        XCTAssertNil(ObsidianTodoMarkdown.removingTask(Self.prep, id: UUID()))
    }

    func testAppendingTaskGoesAfterLastCheckboxItemAndItsNestedLines() {
        let id = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let updated = ObsidianTodoMarkdown.appendingTask(
            Self.prep,
            .init(id: id, text: "New one", isCompleted: false)
        )
        XCTAssertEqual(
            updated,
            Self.prep.replacingOccurrences(
                of: "    wrapped continuation\n",
                with: "    wrapped continuation\n- [ ] New one <!-- casablanca-todo: CCCCCCCC-0000-0000-0000-000000000003 -->\n"
            )
        )
    }

    func testAppendingTaskCreatesSectionWhenMissing() {
        let task = ObsidianTodoMarkdown.TaskLine(id: Self.idA, text: "First", isCompleted: false)
        let line = "- [ ] First <!-- casablanca-todo: AAAAAAAA-0000-0000-0000-000000000001 -->"
        XCTAssertEqual(ObsidianTodoMarkdown.appendingTask("", task), "## Action Items\n\n\(line)\n")
        XCTAssertEqual(ObsidianTodoMarkdown.appendingTask("# Prep\n", task), "# Prep\n\n## Action Items\n\n\(line)\n")
        XCTAssertEqual(ObsidianTodoMarkdown.appendingTask("# Prep", task), "# Prep\n\n## Action Items\n\n\(line)\n")
        XCTAssertEqual(
            ObsidianTodoMarkdown.appendingTask("## Action Items\n\n## Notes\nx", task),
            "## Action Items\n\n\(line)\n\n## Notes\nx"
        )
        XCTAssertEqual(
            ObsidianTodoMarkdown.appendingTask("## Action Items\n## Notes", task),
            "## Action Items\n\n\(line)\n\n## Notes"
        )
    }

    func testAssigningMissingTaskIDsEditsOnlyIDlessTaskLines() throws {
        let markdown = Self.prep.replacingOccurrences(
            of: "* [ ] Star task\n",
            with: "* [ ] Star task\n- [ ] Untracked\n"
        )
        let (updated, tasks) = ObsidianTodoMarkdown.assigningMissingTaskIDs(markdown)

        XCTAssertEqual(tasks.map(\.text), ["Bring roadmap slide", "Untracked", "Mail agenda"])
        let newID = try XCTUnwrap(tasks[1].id)
        XCTAssertEqual(
            updated,
            markdown.replacingOccurrences(
                of: "- [ ] Untracked\n",
                with: "- [ ] Untracked <!-- casablanca-todo: \(newID.uuidString.uppercased()) -->\n"
            )
        )
        let (unchanged, _) = ObsidianTodoMarkdown.assigningMissingTaskIDs(Self.prep)
        XCTAssertEqual(unchanged, Self.prep)
    }

    func testInPlaceEditsPreserveCRLFLineEndings() throws {
        let crlf = Self.prep.replacingOccurrences(of: "\n", with: "\r\n")
        let toggled = try XCTUnwrap(ObsidianTodoMarkdown.settingTaskCompletion(crlf, id: Self.idA, isCompleted: true))
        XCTAssertEqual(toggled, crlf.replacingOccurrences(of: "- [ ] Bring roadmap slide", with: "- [x] Bring roadmap slide"))
        let appended = ObsidianTodoMarkdown.appendingTask(crlf, .init(id: Self.idA, text: "X", isCompleted: false))
        XCTAssertFalse(appended.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testH1AfterActionItemsClosesTheSection() {
        let markdown = "## Action Items\n- [ ] Real\n# Appendix\n- [ ] Not an action item"
        XCTAssertEqual(ObsidianTodoMarkdown.parseMeetingActionItems(markdown).map(\.text), ["Real"])
    }

    // MARK: - Task 10: owner / due / timestamp suffix

    private let suffixID = UUID(uuidString: "880E8400-E29B-41D4-A716-446655440000")!

    func testRendersOwnerDueAndTimestampSuffix() {
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(owner: "Youri", due: "2026-11-06", timestamp: "12:34"),
                       " — Youri 📅 2026-11-06 [12:34]")
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(owner: nil, due: nil, timestamp: nil), "")
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(owner: nil, due: "2026-11-06", timestamp: nil), " 📅 2026-11-06")
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(owner: "Kim", due: nil, timestamp: "1:02:03"), " — Kim [1:02:03]")

        let task = ObsidianTodoMarkdown.TaskLine(id: suffixID, text: "Stuur offerte", isCompleted: false,
                                                 owner: "Youri", due: "2026-11-06", timestamp: "12:34")
        let markdown = ObsidianTodoMarkdown.appendingTask("", task)

        XCTAssertEqual(markdown, """
        ## Action Items

        - [ ] Stuur offerte — Youri 📅 2026-11-06 [12:34] <!-- casablanca-todo: 880E8400-E29B-41D4-A716-446655440000 -->

        """)
    }

    func testParsesSuffixIntoFields() {
        let markdown = """
        ## Action Items

        - [ ] Stuur offerte — Youri 📅 2026-11-06 [12:34] <!-- casablanca-todo: 880E8400-E29B-41D4-A716-446655440000 -->
        - [x] Mail Kim 📅 2026-11-07
        - [ ] Plan de demo — Kim [1:02:03]
        """

        let items = ObsidianTodoMarkdown.parseMeetingActionItems(markdown)

        XCTAssertEqual(items, [
            .init(id: suffixID, text: "Stuur offerte", isCompleted: false, owner: "Youri", due: "2026-11-06", timestamp: "12:34"),
            .init(id: nil, text: "Mail Kim", isCompleted: true, owner: nil, due: "2026-11-07", timestamp: nil),
            .init(id: nil, text: "Plan de demo", isCompleted: false, owner: "Kim", due: nil, timestamp: "1:02:03"),
        ])
    }

    func testOwnerAloneIsNotWritten() {
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(owner: "Youri", due: nil, timestamp: nil), "")
        let task = ObsidianTodoMarkdown.TaskLine(id: suffixID, text: "Bel Kim", isCompleted: false, owner: "Youri")
        let markdown = ObsidianTodoMarkdown.appendingTask("", task)
        XCTAssertTrue(markdown.contains("- [ ] Bel Kim <!-- casablanca-todo: 880E8400-E29B-41D4-A716-446655440000 -->"))
        XCTAssertFalse(markdown.contains("Youri"))
        // An owner that would not parse back is dropped, never mangled.
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(owner: "A — B", due: "2026-11-06", timestamp: nil), " 📅 2026-11-06")
    }

    func testUserTypedDashLineKeepsItsText() {
        let items = ObsidianTodoMarkdown.parseMeetingActionItems("## Action Items\n\n- [ ] Bel Kim — dringend\n")
        XCTAssertEqual(items.first?.text, "Bel Kim — dringend")
        XCTAssertNil(items.first?.owner)
        XCTAssertNil(items.first?.due)
        XCTAssertNil(items.first?.timestamp)
    }

    func testBracketTextThatIsNotATimestampStaysText() {
        let items = ObsidianTodoMarkdown.parseMeetingActionItems("""
        ## Action Items

        - [ ] Check [IO-12]
        - [ ] Review — Kim [IO-12]
        - [ ] Plan sprint 📅 volgende week
        """)
        XCTAssertEqual(items.map(\.text), ["Check [IO-12]", "Review — Kim [IO-12]", "Plan sprint 📅 volgende week"])
        XCTAssertTrue(items.allSatisfy { $0.owner == nil && $0.due == nil && $0.timestamp == nil })
    }

    func testSettingCompletionKeepsSuffix() throws {
        let line = "- [ ] Stuur offerte — Youri 📅 2026-11-06 [12:34] <!-- casablanca-todo: 880E8400-E29B-41D4-A716-446655440000 -->"
        let markdown = "## Action Items\n\n\(line)\n"

        let updated = try XCTUnwrap(ObsidianTodoMarkdown.settingTaskCompletion(markdown, id: suffixID, isCompleted: true))

        XCTAssertTrue(updated.contains("- [x] Stuur offerte — Youri 📅 2026-11-06 [12:34] <!-- casablanca-todo:"))
        let task = try XCTUnwrap(ObsidianTodoMarkdown.parseMeetingActionItems(updated).first)
        XCTAssertEqual(task.owner, "Youri")
        XCTAssertEqual(task.due, "2026-11-06")
        XCTAssertEqual(task.timestamp, "12:34")
        XCTAssertTrue(task.isCompleted)
    }

    /// Assigning a missing id keeps the line's suffix and its fields.
    func testAssigningMissingIDKeepsSuffixFields() throws {
        let markdown = "## Action Items\n\n- [ ] Mail Kim — Youri 📅 2026-11-07\n"
        let (updated, tasks) = ObsidianTodoMarkdown.assigningMissingTaskIDs(markdown)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.text, "Mail Kim")
        XCTAssertEqual(task.owner, "Youri")
        XCTAssertEqual(task.due, "2026-11-07")
        XCTAssertTrue(updated.contains("- [ ] Mail Kim — Youri 📅 2026-11-07 <!-- casablanca-todo: \(task.id!.uuidString) -->"))
    }

    // MARK: - Fix round 1

    /// Summary-tab to-dos store the whole bullet; their text is never split.
    func testBulletOwnerLinesKeepTheirWholeText() {
        let items = ObsidianTodoMarkdown.parseMeetingActionItems("""
        ## Action Items

        - [ ] **Youri** — Plan de demo [00:20]
        - [ ] **?** — Plan de demo (2026-11-06) [00:20]
        - [ ] **Youri:** Mail Kim 📅 2026-11-06
        """)
        XCTAssertEqual(items.map(\.text), [
            "**Youri** — Plan de demo [00:20]",
            "**?** — Plan de demo (2026-11-06) [00:20]",
            "**Youri:** Mail Kim 📅 2026-11-06",
        ])
        XCTAssertTrue(items.allSatisfy { $0.owner == nil && $0.due == nil && $0.timestamp == nil })
    }

    func testImpossibleDueDateStaysText() throws {
        let markdown = "## Action Items\n\n- [ ] Mail Kim 📅 2026-02-30 <!-- casablanca-todo: 880E8400-E29B-41D4-A716-446655440000 -->\n"
        let task = try XCTUnwrap(ObsidianTodoMarkdown.parseMeetingActionItems(markdown).first)
        XCTAssertEqual(task.text, "Mail Kim 📅 2026-02-30")
        XCTAssertNil(task.due)
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(owner: "Kim", due: "2026-02-30", timestamp: nil), "")
        // A re-render keeps the text instead of dropping the date.
        XCTAssertEqual(
            ObsidianTodoMarkdown.renderMeetingDocument(markdown, actionItems: [task]),
            "## Action Items\n\n- [ ] Mail Kim 📅 2026-02-30 <!-- casablanca-todo: 880E8400-E29B-41D4-A716-446655440000 -->"
        )
    }
}
