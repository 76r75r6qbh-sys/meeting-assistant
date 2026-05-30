// CasablancaTests/SummaryResponseParserTests.swift
import XCTest
@testable import Casablanca

final class SummaryResponseParserTests: XCTestCase {

    func test_fullResponse_extractsSummaryAndTodos() {
        let raw = """
        # Summary

        The team agreed to ship by Friday.

        ## Decisions

        - Use SwiftUI for the new dashboard.

        ## Action Items

        - Send the build to QA
        - Update the changelog
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertTrue(result.summary.contains("The team agreed to ship by Friday."))
        XCTAssertEqual(result.todoTexts, ["Send the build to QA", "Update the changelog"])
    }

    func test_noActionItems_returnsEmptyTodos() {
        let raw = """
        # Summary

        Informational meeting, no actions.

        ## Action Items
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertTrue(result.summary.contains("Informational meeting, no actions."))
        XCTAssertTrue(result.todoTexts.isEmpty)
    }

    func test_malformedResponse_treatsEntireResponseAsSummary() {
        let raw = "The model just wrote prose with no structure at all."
        let result = SummaryResponseParser.parse(raw)
        XCTAssertEqual(result.summary, raw)
        XCTAssertTrue(result.todoTexts.isEmpty)
    }

    func test_actionItemsWithOwners_preservesFull() {
        let raw = """
        # Summary

        Quick sync.

        ## Action Items

        - @Alice: Draft the proposal by Thursday
        - @Bob: Review the API spec
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertEqual(result.todoTexts, [
            "@Alice: Draft the proposal by Thursday",
            "@Bob: Review the API spec"
        ])
    }

    func test_splitsAllSections() {
        let md = """
        # Summary
        Aligned on the plan.
        ## Decisions
        - Team Link owns mapping
        ## Action Items
        - Draft spec
        ## Risks and Blockers
        - Test env may slip
        ## Follow-ups
        - Ping Manon
        """
        let r = SummaryResponseParser.parse(md)
        XCTAssertTrue(r.summary.contains("Aligned on the plan."))
        XCTAssertEqual(r.todoTexts, ["Draft spec"])
        XCTAssertEqual(r.decisions, ["Team Link owns mapping"])
        XCTAssertEqual(r.risks, ["Test env may slip"])
        XCTAssertEqual(r.followUps, ["Ping Manon"])
        XCTAssertEqual(r.rawMarkdown, md)
    }

    func test_omitsEmptySections() {
        let md = "# Summary\nDone.\n## Action Items\n## Risks and Blockers\n"
        let r = SummaryResponseParser.parse(md)
        XCTAssertEqual(r.todoTexts, [])
        XCTAssertEqual(r.risks, [])
        XCTAssertEqual(r.decisions, [])
    }
}
