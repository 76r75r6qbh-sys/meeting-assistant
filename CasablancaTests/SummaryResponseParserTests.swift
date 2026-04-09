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

    func test_extraSectionsAfterActionItems_ignored() {
        let raw = """
        # Summary

        All good.

        ## Action Items

        - Ship it

        ## Follow-ups

        - Check metrics next week
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertEqual(result.todoTexts, ["Ship it"])
    }
}
