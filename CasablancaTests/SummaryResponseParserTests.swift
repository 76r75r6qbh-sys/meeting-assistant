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

    // MARK: - Dutch header alias tests

    /// Full Dutch document with thematic sections plus all four known Dutch headers.
    /// Uses U+2019 typographic apostrophe in "Risico\u{2019}s en blockers".
    func test_dutchHeaders_fullDocument_typographicApostrophe() {
        let md = """
        # Samenvatting

        Bespreking over de technische transitie en planning.

        ## Technische transitie

        We migreren van Mirth naar Orchestra op Azure.

        ## Planning

        Sprint start volgende week.

        ## Besluiten

        - Migratie start in sprint 2026.4.1

        ## Actiepunten

        - **Wesley** \u{2014} Juno-node onderzoeken
        - Documentatie bijwerken

        ## Risico\u{2019}s en blockers

        - Testomgeving loopt achter

        ## Opvolging

        - Frank bijpraten over besluit
        """
        let r = SummaryResponseParser.parse(md)

        // Intro contains only lead text, not thematic section content
        XCTAssertTrue(r.summary.contains("Bespreking over de technische transitie en planning."))
        XCTAssertFalse(r.summary.contains("We migreren van Mirth naar Orchestra op Azure."),
                       "Thematic section content must not bleed into summary")
        XCTAssertFalse(r.summary.contains("Sprint start volgende week."),
                       "Thematic section content must not bleed into summary")

        // Four known sections are populated
        XCTAssertEqual(r.decisions, ["Migratie start in sprint 2026.4.1"])
        XCTAssertEqual(r.todoTexts, [
            "**Wesley** \u{2014} Juno-node onderzoeken",
            "Documentatie bijwerken"
        ])
        XCTAssertEqual(r.risks, ["Testomgeving loopt achter"])
        XCTAssertEqual(r.followUps, ["Frank bijpraten over besluit"])
    }

    /// Same as above but uses ASCII apostrophe in "Risico's" — both must match.
    func test_dutchHeaders_risicosWithAsciiApostrophe() {
        let md = """
        # Samenvatting

        Kort overleg.

        ## Risico's en blockers

        - Deadline is krap
        """
        let r = SummaryResponseParser.parse(md)
        XCTAssertEqual(r.risks, ["Deadline is krap"])
    }

    /// Trailing colon on a Dutch header must be stripped before matching.
    func test_dutchHeader_trailingColon_matches() {
        let md = """
        # Samenvatting

        Planning bespreking.

        ## Actiepunten:

        - Spec opstellen
        """
        let r = SummaryResponseParser.parse(md)
        XCTAssertEqual(r.todoTexts, ["Spec opstellen"])
    }

    /// Owner-formatted bullet must come through verbatim as todo text.
    func test_ownerFormattedBullet_verbatim() {
        let md = """
        # Summary

        Quick sync.

        ## Actiepunten

        - **Wesley** \u{2014} Juno-node onderzoeken
        """
        let r = SummaryResponseParser.parse(md)
        XCTAssertEqual(r.todoTexts, ["**Wesley** \u{2014} Juno-node onderzoeken"])
    }
}
