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

    func testSummaryStripsYAMLFrontmatter() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertFalse(html.contains("---"))
        XCTAssertFalse(html.contains("casablanca_type"))
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
