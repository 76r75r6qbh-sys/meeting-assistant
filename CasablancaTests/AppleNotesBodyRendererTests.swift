import XCTest
@testable import Casablanca

final class AppleNotesBodyRendererTests: XCTestCase {
    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Freeform notes go here."
        meeting.summary = "We agreed on next steps."
        let todoOpen = TodoItem(text: "Send recap", isCompleted: false)
        let todoDone = TodoItem(text: "Book room", isCompleted: true)
        meeting.todos = [todoOpen, todoDone]
        return meeting
    }

    func testSummaryWrapsInHTMLDocument() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertTrue(html.hasPrefix("<html><body>"))
        XCTAssertTrue(html.hasSuffix("</body></html>"))
    }

    func testSummaryTitleIncludesDatePrefix() {
        // Apple Notes derives its visible note title from the first <h1>, not the AppleScript
        // `name` property. The H1 must therefore mirror the dated file-name convention
        // (`YYYY-MM-DD <title>`) so the note shows up correctly in the Notes sidebar.
        let meeting = makeMeeting()
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("<h1>\(meeting.obsidianFileName)</h1>"),
            "Summary H1 should be the dated file-name; got: \(html)")
    }

    func testRawNotesTitleIncludesDatePrefix() {
        let meeting = makeMeeting()
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        XCTAssertTrue(html.contains("<h1>\(meeting.obsidianFileName) - Notes</h1>"),
            "Raw-notes H1 should be the dated file-name + ' - Notes'; got: \(html)")
    }

    func testSummaryNeverEmitsYAMLFrontmatterMarkers() {
        // Even if summary text contains YAML-like delimiters, the renderer must not
        // accidentally re-emit them as raw markers in the HTML (no `---` or `casablanca_type`
        // tokens, which the Obsidian exporter uses but Notes shouldn't see).
        let meeting = makeMeeting()
        meeting.summary = """
        ---
        casablanca_type: "meeting-summary"
        ---

        Real summary text.
        """
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        // The YAML delimiters survive as escaped text inside <p>, which is fine — but they must
        // not appear as the top-level prefix nor as recognized YAML structure.
        XCTAssertTrue(html.hasPrefix("<html><body>"))
        XCTAssertFalse(html.contains("<p>---</p>"),
            "Standalone YAML delimiter line shouldn't render as its own paragraph token")
        XCTAssertTrue(html.contains("Real summary text."))
    }

    func testFreeformParagraphsPreserveSingleLineBreaks() {
        let meeting = makeMeeting()
        meeting.userNotes = "Line one\nLine two\n\nNext paragraph"
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        XCTAssertTrue(html.contains("<p>Line one<br>Line two</p>"),
            "Single \\n inside a paragraph should render as <br>; got: \(html)")
        XCTAssertTrue(html.contains("<p>Next paragraph</p>"))
    }

    func testSummaryFlattensWikilinks() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertFalse(html.contains("[["))
        XCTAssertFalse(html.contains("]]"))
    }

    func testSummaryRendersTodosWithGlyphs() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertTrue(html.contains("<li>☐ Send recap</li>"))
        XCTAssertTrue(html.contains("<li>☑ Book room</li>"))
    }

    func testSummaryEmbedsMarkerInTrailingParagraph() {
        let meeting = makeMeeting()
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        let expectedMarker = "Casablanca id: \(meeting.id.uuidString) / summary"
        XCTAssertTrue(html.contains("<p>\(expectedMarker)</p></body></html>"),
            "Marker should be the last <p> before </body>; got: \(html)")
    }

    func testRawNotesEmbedsNotesMarker() {
        let meeting = makeMeeting()
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        let expectedMarker = "Casablanca id: \(meeting.id.uuidString) / notes"
        XCTAssertTrue(html.contains("<p>\(expectedMarker)</p></body></html>"))
    }

    func testRawNotesContainsFreeformSection() {
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: makeMeeting())
        XCTAssertTrue(html.contains("Freeform Notes"))
        XCTAssertTrue(html.contains("Freeform notes go here."))
    }

    func testHTMLEscapesUserContent() {
        let meeting = Meeting(title: "<script>alert(1)</script>", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "5 < 6 & 7 > 4"
        meeting.summary = nil
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("5 &lt; 6 &amp; 7 &gt; 4"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testSummaryOmittedWhenSummaryIsEmpty() {
        let meeting = makeMeeting()
        meeting.summary = "  "
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("Casablanca id:"))
    }

    // MARK: - Markdown → HTML conversion (the summary block ships as raw markdown today;
    // these tests force the renderer to interpret common markdown structures so Notes shows
    // formatted output instead of literal `##`, `-`, and `**` glyphs.)

    func testSummaryConvertsMarkdownHeadings() {
        let meeting = makeMeeting()
        meeting.summary = "## Decisions\n\nFirst decision\n\n### Sub heading\n\nMore text"
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("<h1>Decisions</h1>"), "## should become <h1>; got: \(html)")
        XCTAssertTrue(html.contains("<h2>Sub heading</h2>"), "### should become <h2>; got: \(html)")
        XCTAssertFalse(html.contains("## Decisions"))
        XCTAssertFalse(html.contains("### Sub heading"))
    }

    func testSummaryConvertsUnorderedLists() {
        let meeting = makeMeeting()
        meeting.summary = "- Apple\n- Banana\n- Cherry"
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("<ul><li>Apple</li><li>Banana</li><li>Cherry</li></ul>"),
            "Unordered bullets should become <ul><li>; got: \(html)")
        XCTAssertFalse(html.contains("- Apple"))
    }

    func testSummaryConvertsOrderedLists() {
        let meeting = makeMeeting()
        meeting.summary = "1. First\n2. Second\n3. Third"
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("<ol><li>First</li><li>Second</li><li>Third</li></ol>"),
            "Numbered items should become <ol><li>; got: \(html)")
    }

    func testSummaryConvertsBoldAndItalic() {
        let meeting = makeMeeting()
        meeting.summary = "Status: **Important** decision. Note: *please review*."
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("<b>Important</b>"), "** should become <b>; got: \(html)")
        XCTAssertTrue(html.contains("<i>please review</i>"), "* should become <i>; got: \(html)")
        XCTAssertFalse(html.contains("**"))
    }

    func testSummaryMixesBlockTypes() {
        let meeting = makeMeeting()
        meeting.summary = """
        ## Key Points

        - Discussed rollout
        - Action: ship Friday

        **Important:** approved by all.
        """
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("<h1>Key Points</h1>"))
        XCTAssertTrue(html.contains("<ul><li>Discussed rollout</li><li>Action: ship Friday</li></ul>"))
        XCTAssertTrue(html.contains("<b>Important:</b>"))
    }

    func testSummaryEscapesHTMLInsideMarkdown() {
        let meeting = makeMeeting()
        meeting.summary = "## A <script>\n\n**Beware:** 5 < 6"
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("<h1>A &lt;script&gt;</h1>"))
        XCTAssertTrue(html.contains("<b>Beware:</b>"))
        XCTAssertTrue(html.contains("5 &lt; 6"))
        XCTAssertFalse(html.contains("<script>"))
    }
}
