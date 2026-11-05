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

    func testNormalizedFoldsPunctuationAndWhitespace() {
        XCTAssertEqual(FuzzyText.normalized("  Bél  Kim — nú!  "), "bel kim nu")
    }

    func testBothEmptyIsOne() {
        XCTAssertEqual(FuzzyText.similarity("", "  ..."), 1.0)
    }
}
