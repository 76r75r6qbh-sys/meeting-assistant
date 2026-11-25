import Foundation
import XCTest
@testable import Casablanca

final class AskTokenizerTests: XCTestCase {

    func testFoldsDiacriticsAndCase() {
        XCTAssertEqual(AskTokenizer.tokens("Geïnteresseerd in IPS"), ["geinteresseerd", "ips"])
    }

    func testCafeAndUmlauts() {
        XCTAssertEqual(AskTokenizer.tokens("café überleg"), ["cafe", "uberleg"])
    }

    func testDropsTimestampsAndSpeakerColon() {
        XCTAssertEqual(AskTokenizer.tokens("[12:34] Joris: offerte"), ["joris", "offerte"])
        let long = AskTokenizer.tokens("[1:02:03] x 42")
        XCTAssertTrue(long.contains("42"))
        XCTAssertFalse(long.contains("12"))
        XCTAssertFalse(long.contains("34"))
        XCTAssertFalse(long.contains("02"))
        XCTAssertFalse(long.contains("03"))
    }

    func testDropsStopwordsBothLanguages() {
        XCTAssertEqual(AskTokenizer.tokens("de offerte van the vendor"), ["offerte", "vendor"])
    }

    func testSplitsOnPunctuationAndHyphens() {
        XCTAssertEqual(AskTokenizer.tokens("IpS-profiel, v2!"), ["ips", "profiel", "v2"])
    }

    func testKeepsDuplicates() {
        XCTAssertEqual(AskTokenizer.tokens("ips ips"), ["ips", "ips"])
    }

    func testEmpty() {
        XCTAssertEqual(AskTokenizer.tokens("  "), [])
        XCTAssertEqual(AskTokenizer.tokens(""), [])
    }

    func testFoldsIJLigature() {
        XCTAssertEqual(AskTokenizer.tokens("Ĳsselmeer ĳs"), ["ijsselmeer", "ijs"])
    }

    func testKeepsSingleDigitsDropsSingleLetters() {
        XCTAssertEqual(AskTokenizer.tokens("sprint 3 x"), ["sprint", "3"])
    }

    func testStopwordsAreFolded() {
        for word in AskTokenizer.stopwords {
            XCTAssertEqual(AskTokenizer.fold(word), word)
        }
        // A diacritic variant of a listed stopword is dropped after folding.
        XCTAssertEqual(AskTokenizer.tokens("dat is wél offerte"), ["offerte"])
    }
}
