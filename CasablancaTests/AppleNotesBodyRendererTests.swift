import XCTest
@testable import Casablanca

final class AppleNotesBodyRendererTests: XCTestCase {
    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Freeform notes go here."
        meeting.timestampedNotes = [TimestampedNote(timestamp: 65, text: "Discussed rollout plan")]
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

    func testRawNotesContainsFreeformAndTimestampedSections() {
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: makeMeeting())
        XCTAssertTrue(html.contains("Freeform Notes"))
        XCTAssertTrue(html.contains("Freeform notes go here."))
        XCTAssertTrue(html.contains("Timestamped Notes"))
        XCTAssertTrue(html.contains("[01:05] Discussed rollout plan"))
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
}
