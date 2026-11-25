import Foundation
import XCTest
@testable import Casablanca

/// Locks the line format that the `add-todo` Claude Code skill
/// (`~/.claude/skills/add-todo/SKILL.md`, section `## Line format`) writes into
/// `tasks/Casablanca Todos.md` to what `ObsidianTodoMarkdown` parses.
///
/// The five `- [ ]` lines below are byte-identical copies of the skill's
/// examples. If you change one here, change it in the skill too (and vice
/// versa): the skill's format and the app's parser must not drift apart.
/// Pure parsing — no file system, no preferences, no vault.
final class AddTodoSkillContractTests: XCTestCase {
    private let skillExampleDocument = """
    # Casablanca Todos

    ## Open
    - [ ] Make the WhatsApp poll for Daily stand-up 🔗 teams:19:meeting_abc@thread.v2/1762073195000
    - [ ] Reply to Marco Smit about the IpS test data 📅 2026-11-20 🔗 outlook:AAMkADExample=
    - [ ] Beantwoord de vraag van Kim over de API-scope 🔗 topdesk:LI2611 0123
    - [ ] Plan bilateral with Martijn de Hoogh 📅 2026-11-27
    - [ ] Send Annelies the partner shortlist 🔗 url:https://your-site.atlassian.net/wiki/spaces/X/pages/1

    ## Done
    """

    private struct Expected {
        let text: String
        let due: String?
        let link: String?
    }

    private let expected: [Expected] = [
        Expected(
            text: "Make the WhatsApp poll for Daily stand-up",
            due: nil,
            link: "teams:19:meeting_abc@thread.v2/1762073195000"
        ),
        Expected(
            text: "Reply to Marco Smit about the IpS test data",
            due: "2026-11-20",
            link: "outlook:AAMkADExample="
        ),
        Expected(
            text: "Beantwoord de vraag van Kim over de API-scope",
            due: nil,
            link: "topdesk:LI2611 0123"
        ),
        Expected(
            text: "Plan bilateral with Martijn de Hoogh",
            due: "2026-11-27",
            link: nil
        ),
        Expected(
            text: "Send Annelies the partner shortlist",
            due: nil,
            link: "url:https://your-site.atlassian.net/wiki/spaces/X/pages/1"
        ),
    ]

    func testSkillExampleLinesParse() {
        let document = ObsidianTodoMarkdown.parseGenericDocument(skillExampleDocument)

        XCTAssertEqual(document.openTasks.count, 5)
        XCTAssertTrue(document.doneTasks.isEmpty)
        for (index, (task, want)) in zip(document.openTasks, expected).enumerated() {
            XCTAssertEqual(task.text, want.text, "text of example \(index)")
            XCTAssertEqual(task.due, want.due, "due of example \(index)")
            XCTAssertEqual(task.link, want.link, "link of example \(index)")
            XCTAssertNil(task.owner, "owner of example \(index)")
            XCTAssertNil(task.timestamp, "timestamp of example \(index)")
            XCTAssertNil(task.id, "id of example \(index)")
            XCTAssertFalse(task.isCompleted, "isCompleted of example \(index)")
        }
    }

    func testRenderRoundTripKeepsLines() {
        let parsed = ObsidianTodoMarkdown.parseGenericDocument(skillExampleDocument)
        let rendered = ObsidianTodoMarkdown.renderGenericDocument(
            openTasks: parsed.openTasks,
            doneTasks: parsed.doneTasks
        )
        let reparsed = ObsidianTodoMarkdown.parseGenericDocument(rendered)

        XCTAssertEqual(reparsed.openTasks.count, parsed.openTasks.count)
        for (index, (before, after)) in zip(parsed.openTasks, reparsed.openTasks).enumerated() {
            XCTAssertEqual(after.text, before.text, "text of example \(index)")
            XCTAssertEqual(after.due, before.due, "due of example \(index)")
            XCTAssertEqual(after.link, before.link, "link of example \(index)")
        }
    }

    /// The hazard the skill forbids: ` — ` before a date makes the parser read
    /// the words after the dash as an owner and drop them from the text.
    func testEmDashBeforeDateIsReadAsOwner() {
        let document = ObsidianTodoMarkdown.parseGenericDocument("""
        # Casablanca Todos

        ## Open
        - [ ] Reply to Kim — API scope 📅 2026-11-20

        ## Done
        """)

        XCTAssertEqual(document.openTasks.count, 1)
        XCTAssertEqual(document.openTasks.first?.text, "Reply to Kim")
        XCTAssertEqual(document.openTasks.first?.owner, "API scope")
        XCTAssertEqual(document.openTasks.first?.due, "2026-11-20")
    }
}
