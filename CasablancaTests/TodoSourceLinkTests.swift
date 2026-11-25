import XCTest
@testable import Casablanca

/// `TodoSourceLink`: the raw `scheme:ref` a to-do line carries after `🔗`,
/// as a label and (where one exists) a URL.
final class TodoSourceLinkTests: XCTestCase {
    func testJiraLinkHasKeyLabelAndBrowseURL() throws {
        let link = try XCTUnwrap(TodoSourceLink("jira:ABC-1234"))
        XCTAssertEqual(link.scheme, .jira)
        XCTAssertEqual(link.ref, "ABC-1234")
        XCTAssertEqual(link.label, "Jira ABC-1234")
        XCTAssertEqual(link.url?.absoluteString, "https://your-site.atlassian.net/browse/ABC-1234")
    }

    func testTopdeskLinkHasTicketLabelAndNoURL() throws {
        let link = try XCTUnwrap(TodoSourceLink("topdesk:LI2611 0123"))
        XCTAssertEqual(link.scheme, .topdesk)
        XCTAssertEqual(link.ref, "LI2611 0123")
        XCTAssertEqual(link.label, "Topdesk LI2611 0123")
        XCTAssertNil(link.url)
    }

    func testOutlookAndTeamsLinksHaveFixedLabelsAndNoURL() throws {
        let outlook = try XCTUnwrap(TodoSourceLink("outlook:AAMkADExample="))
        XCTAssertEqual(outlook.label, "Outlook email")
        XCTAssertNil(outlook.url)

        let teams = try XCTUnwrap(TodoSourceLink("teams:19:abc@thread.v2"))
        XCTAssertEqual(teams.ref, "19:abc@thread.v2", "only the first colon splits scheme from ref")
        XCTAssertEqual(teams.label, "Teams chat")
        XCTAssertNil(teams.url)
    }

    func testURLLinkShowsTheHost() throws {
        let link = try XCTUnwrap(TodoSourceLink("url:https://example.com/a"))
        XCTAssertEqual(link.scheme, .url)
        XCTAssertEqual(link.label, "example.com")
        XCTAssertEqual(link.url?.absoluteString, "https://example.com/a")
    }

    /// Only web links open: a `url:` ref with another scheme (`file:`, an app
    /// scheme) shows as text and is not clickable.
    func testURLLinkOnlyOpensWebURLs() throws {
        let link = try XCTUnwrap(TodoSourceLink("url:file:///Applications/Calculator.app"))
        XCTAssertNil(link.url)
        XCTAssertEqual(link.label, "file:///Applications/Calculator.app")
    }

    func testUnknownSchemeOrEmptyRefIsNil() {
        XCTAssertNil(TodoSourceLink("bogus:x"))
        XCTAssertNil(TodoSourceLink("jira:"))
        XCTAssertNil(TodoSourceLink("jira"))
        XCTAssertNil(TodoSourceLink(""))
    }

    func testEverySchemeIsALineLinkScheme() {
        let schemes = Set([TodoSourceLink.Scheme.outlook, .teams, .jira, .topdesk, .url].map(\.rawValue))
        XCTAssertEqual(schemes, ObsidianTodoMarkdown.linkSchemes)
    }

    @MainActor
    func testRowPresentationExposesTheSourceLink() {
        let todo = TodoItem(text: "Reply to Kim")
        XCTAssertNil(TodoRowPresentation(todo: todo).sourceLink)

        todo.sourceRef = "jira:ABC-1234"
        XCTAssertEqual(TodoRowPresentation(todo: todo).sourceLink?.label, "Jira ABC-1234")

        todo.sourceRef = "bogus:x"
        XCTAssertNil(TodoRowPresentation(todo: todo).sourceLink)
    }
}
