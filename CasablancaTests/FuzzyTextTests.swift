import XCTest
@testable import Casablanca

final class FuzzyTextTests: XCTestCase {
    func testIdenticalAfterNormalisationIsOne() {
        XCTAssertEqual(FuzzyText.similarity("Ik pak het op.", "ik pak het op"), 1.0)
    }

    func testDiacriticsFold() {
        XCTAssertEqual(FuzzyText.similarity("één", "een"), 1.0)
    }

    func testUnrelatedIsLow() {
        XCTAssertLessThan(FuzzyText.similarity("Bel de leverancier", "Plan een demo met het team"), 0.5)
    }

    func testNearMissAboveThreshold() {
        let a = "Stuur de offerte voor het project naar Kim"
        let b = "Stuur de oferte voor het project naar Kim"
        XCTAssertGreaterThanOrEqual(FuzzyText.similarity(a, b), FuzzyText.matchThreshold)
    }

    func testNormalizedFoldsTheIJLigature() {
        XCTAssertEqual(FuzzyText.normalized("Ĳsbaan bĳ de dĳk"), "ijsbaan bij de dijk")
        XCTAssertEqual(FuzzyText.similarity("bĳeenkomst", "bijeenkomst"), 1.0)
    }

    func testNormalizedFoldsPunctuationAndWhitespace() {
        XCTAssertEqual(FuzzyText.normalized("  Bél  Kim — nú!  "), "bel kim nu")
    }

    // MARK: - Fuzzy equality (merge check)

    func testDifferentDigitTokensNeverMatch() {
        XCTAssertGreaterThanOrEqual(FuzzyText.similarity("Plan Q3", "Plan Q4"), FuzzyText.matchThreshold)
        XCTAssertFalse(FuzzyText.isFuzzyEqual("Plan Q3", "Plan Q4"))
        XCTAssertFalse(FuzzyText.isFuzzyEqual("Stuur de offerte voor sprint 12 naar Kim", "Stuur de offerte voor sprint 13 naar Kim"))
    }

    func testShortTextsNeedExactNormalisedEquality() {
        XCTAssertGreaterThanOrEqual(FuzzyText.similarity("Bel Kim", "Bel Tim"), FuzzyText.matchThreshold)
        XCTAssertFalse(FuzzyText.isFuzzyEqual("Bel Kim", "Bel Tim"))
        XCTAssertTrue(FuzzyText.isFuzzyEqual("Bel Kim.", "bel kim"))
        XCTAssertTrue(FuzzyText.isFuzzyEqual("Plan Q3!", "plan q3"))
    }

    func testLongNearDuplicateStillMatches() {
        XCTAssertTrue(FuzzyText.isFuzzyEqual("Stuur offerte naar Kim", "Stuur de offerte naar Kim."))
        XCTAssertTrue(FuzzyText.isFuzzyEqual("Stuur de offerte voor sprint 12 naar Kim", "Stuur de oferte voor sprint 12 naar Kim"))
    }

    func testBothEmptyIsOne() {
        XCTAssertEqual(FuzzyText.similarity("", "  ..."), 1.0)
    }
}
