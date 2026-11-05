// CasablancaTests/ActionItemRenderingTests.swift
import XCTest
@testable import Casablanca

final class ActionItemRenderingTests: XCTestCase {
    private func item(
        _ task: String, owner: String? = nil, due: String? = nil, timestamp: String? = nil
    ) -> ExtractedActionItem {
        ExtractedActionItem(task: task, owner: owner, due: due, dueIsExplicit: due != nil, confidence: 0.8,
                            quote: nil, timestamp: timestamp, verified: .unverified, verificationReason: nil)
    }

    private let dutchNotes = """
    # Samenvatting
    Kim stuurt de offerte.

    ## Offerte
    - **prijs:** akkoord

    ## Besluiten
    - We gaan door

    ## Actiepunten
    - **Kim** — Mail de offerte
    - **?** — Plan demo

    ## Risico's en blockers
    - Budget

    ## Opvolging
    """

    // MARK: Bullets

    func testBulletWithOwnerDueAndTimestamp() {
        XCTAssertEqual(
            ActionItemRendering.bullet(for: item("Stuur offerte", owner: "Kim", due: "2026-11-06", timestamp: "12:34")),
            "**Kim** — Stuur offerte (2026-11-06) [12:34]"
        )
    }

    func testBulletWithoutOwnerUsesQuestionMark() {
        XCTAssertEqual(ActionItemRendering.bullet(for: item("Plan demo")), "**?** — Plan demo")
        XCTAssertEqual(ActionItemRendering.bullet(for: item("Plan demo", timestamp: "1:02:03")), "**?** — Plan demo [1:02:03]")
    }

    func testBulletKeepsAMultiLineTaskOnOneLine() {
        XCTAssertEqual(ActionItemRendering.bullet(for: item("Stuur\n offerte", owner: "Kim")), "**Kim** — Stuur offerte")
    }

    func testUnsupportedDecisionGetsWarningPrefix() {
        let unsupported = ExtractedDecision(text: "We gaan door", timestamp: "03:10", verified: .unsupported)
        XCTAssertEqual(ActionItemRendering.decisionBullet(for: unsupported), "⚠︎ We gaan door [03:10]")
        XCTAssertEqual(ActionItemRendering.decisionBullet(for: ExtractedDecision(text: "We gaan door", timestamp: "03:10")),
                       "We gaan door [03:10]")
        XCTAssertEqual(ActionItemRendering.decisionBullet(for: ExtractedDecision(text: "We gaan door", verified: .supported)),
                       "We gaan door")
    }

    // MARK: Sections

    func testReplacesDutchActiepuntenBody() {
        let result = ActionItemRendering.replacingSection(
            .actionItems, in: dutchNotes,
            bullets: ["**Kim** — Mail de offerte (2026-11-06) [00:10]"]
        )
        let expected = dutchNotes.replacingOccurrences(
            of: "## Actiepunten\n- **Kim** — Mail de offerte\n- **?** — Plan demo\n",
            with: "## Actiepunten\n- **Kim** — Mail de offerte (2026-11-06) [00:10]\n"
        )
        XCTAssertEqual(result, expected, "only the Actiepunten body changes; every other byte is identical")
    }

    func testInsertsMissingSectionAfterDecisions() {
        let notes = """
        # Samenvatting
        Kort.

        ## Besluiten
        - We gaan door

        ## Risico's en blockers
        - Budget
        """
        let result = ActionItemRendering.replacingSection(.actionItems, in: notes, bullets: ["**Kim** — Mail"])
        XCTAssertEqual(result, """
        # Samenvatting
        Kort.

        ## Besluiten
        - We gaan door

        ## Actiepunten
        - **Kim** — Mail

        ## Risico's en blockers
        - Budget
        """)
    }

    func testInsertsMissingEnglishSectionsBeforeRisksOrAtTheEnd() {
        let withRisks = "# Summary\nShort.\n\n## Risks and Blockers\n- Budget"
        XCTAssertEqual(
            ActionItemRendering.replacingSection(.decisions, in: withRisks, bullets: ["Ship it"]),
            "# Summary\nShort.\n\n## Decisions\n- Ship it\n\n## Risks and Blockers\n- Budget"
        )
        XCTAssertEqual(
            ActionItemRendering.replacingSection(.actionItems, in: "# Summary\nShort.\n", bullets: ["**?** — Mail"]),
            "# Summary\nShort.\n\n## Action Items\n- **?** — Mail\n"
        )
    }

    func testDecisionsAreInsertedBeforeActionItems() {
        let notes = "# Summary\nShort.\n\n## Action Items\n- **?** — Mail\n"
        XCTAssertEqual(
            ActionItemRendering.replacingSection(.decisions, in: notes, bullets: ["Ship it"]),
            "# Summary\nShort.\n\n## Decisions\n- Ship it\n\n## Action Items\n- **?** — Mail\n"
        )
    }

    func testEmptyListKeepsHeading() {
        let result = ActionItemRendering.replacingSection(.actionItems, in: dutchNotes, bullets: [])
        XCTAssertTrue(result.contains("## Actiepunten\n\n## Risico's en blockers"))
        XCTAssertTrue(SummaryResponseParser.parse(result).todoTexts.isEmpty)
        XCTAssertEqual(SummaryResponseParser.parse(result).risks, ["Budget"])
    }

    func testRenderedSummaryRoundTripsThroughParserAndOwnership() {
        var facts = SummaryFacts.empty
        facts.actionItems = [item("Stuur offerte", owner: "Kim", due: "2026-11-06", timestamp: "12:34")]
        facts.decisions = [ExtractedDecision(text: "We gaan door", timestamp: "03:10")]

        let rendered = ActionItemRendering.render(facts, into: dutchNotes)
        let parsed = SummaryResponseParser.parse(rendered)

        XCTAssertEqual(parsed.decisions, ["We gaan door [03:10]"])
        XCTAssertEqual(parsed.todoTexts.count, 1)
        let ownership = ActionItemOwnership.parse(parsed.todoTexts[0])
        XCTAssertEqual(ownership.owner, "Kim")
        XCTAssertEqual(ActionItemRendering.strippingSuffix(ownership.action), "Stuur offerte")
        XCTAssertEqual(parsed.risks, ["Budget"])
    }

    func testRenderKeepsTheMarkdownDecisionsWhenTheFactsHaveNone() {
        var facts = SummaryFacts.empty
        facts.actionItems = [item("Stuur offerte", owner: "Kim")]
        let parsed = SummaryResponseParser.parse(ActionItemRendering.render(facts, into: dutchNotes))
        XCTAssertEqual(parsed.decisions, ["We gaan door"])
        XCTAssertEqual(parsed.todoTexts, ["**Kim** — Stuur offerte"])
    }

    // MARK: Suffix

    func testStrippingSuffixLeavesPlainTextAlone() {
        XCTAssertEqual(ActionItemRendering.strippingSuffix("Bel [Kim]"), "Bel [Kim]")
        XCTAssertEqual(ActionItemRendering.strippingSuffix("Check [IO-12]"), "Check [IO-12]")
        XCTAssertEqual(ActionItemRendering.strippingSuffix("Plan demo"), "Plan demo")
        XCTAssertEqual(ActionItemRendering.strippingSuffix("Plan (concept)"), "Plan (concept)")
    }

    func testStrippingSuffixDropsDueAndTimestamp() {
        XCTAssertEqual(ActionItemRendering.strippingSuffix("Stuur offerte (2026-11-06) [12:34]"), "Stuur offerte")
        XCTAssertEqual(ActionItemRendering.strippingSuffix("Stuur offerte [1:02:03]"), "Stuur offerte")
        XCTAssertEqual(ActionItemRendering.strippingSuffix("Stuur offerte (2026-11-06)"), "Stuur offerte")
    }

    /// Review fix 3: a second alias heading for the same section is removed,
    /// so the model's stale bullets cannot reach an export.
    func testDuplicateAliasSectionsAreRemoved() {
        let notes = """
        # Samenvatting
        Kort.

        ## Action Items
        - **Kim** — Oud punt

        ## Besluiten
        - We gaan door

        ## Actiepunten
        - **Kim** — Ander oud punt
        - **?** — Nog een

        ## Actielijst
        - **?** — Derde

        ## Risico's en blockers
        - Budget
        """
        let result = ActionItemRendering.replacingSection(.actionItems, in: notes, bullets: ["**Kim** — Nieuw"])
        XCTAssertEqual(result, """
        # Samenvatting
        Kort.

        ## Action Items
        - **Kim** — Nieuw

        ## Besluiten
        - We gaan door

        ## Risico's en blockers
        - Budget
        """)
        XCTAssertEqual(SummaryResponseParser.parse(result).todoTexts, ["**Kim** — Nieuw"])
    }

    func testDuplicateAliasSectionAtTheEndIsRemoved() {
        let notes = "# Summary\nShort.\n\n## Decisions\n- Old\n\n## Action Items\n- **?** — Mail\n\n## Besluiten\n- Stale\n"
        XCTAssertEqual(
            ActionItemRendering.replacingSection(.decisions, in: notes, bullets: ["New"]),
            "# Summary\nShort.\n\n## Decisions\n- New\n\n## Action Items\n- **?** — Mail\n"
        )
    }
}
