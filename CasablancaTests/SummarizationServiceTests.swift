import XCTest
@testable import Casablanca

@MainActor
final class SummarizationServiceTests: XCTestCase {
    func testDefaultPromptTemplatePlacesFreeformNotesBeforeTimestampedNotes() {
        let template = SummarizationService.defaultPromptTemplate

        let freeformRange = try? XCTUnwrap(template.range(of: "Freeform notes:"))
        let timestampedRange = try? XCTUnwrap(template.range(of: "Timestamped notes (optional history):"))

        XCTAssertNotNil(freeformRange)
        XCTAssertNotNil(timestampedRange)

        if let freeformRange, let timestampedRange {
            XCTAssertLessThan(freeformRange.lowerBound, timestampedRange.lowerBound)
        }

        XCTAssertTrue(template.contains("{{freeform_notes}}"))
        XCTAssertTrue(template.contains("{{timestamped_notes}}"))
    }

    func testRenderPromptKeepsFreeformBeforeTimestampedNotes() {
        let meeting = Meeting(title: "Design Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: SummarizationService.defaultPromptTemplate,
            meeting: meeting,
            transcript: "Transcript body",
            timestampedNotes: "00:42 Captured timestamped note",
            freeformNotes: "Freeform notes body",
            terminologyBlock: ""
        )

        let freeformRange = try? XCTUnwrap(rendered.range(of: "Freeform notes:\nFreeform notes body"))
        let timestampedRange = try? XCTUnwrap(rendered.range(of: "Timestamped notes (optional history):\n00:42 Captured timestamped note"))

        XCTAssertNotNil(freeformRange)
        XCTAssertNotNil(timestampedRange)

        if let freeformRange, let timestampedRange {
            XCTAssertLessThan(freeformRange.lowerBound, timestampedRange.lowerBound)
        }
    }
}
