import SwiftUI
import XCTest
@testable import Casablanca

final class StringHighlightingTests: XCTestCase {

    /// Counts how many runs in the AttributedString carry the highlight accent
    /// color (the semibold accent applied to matches).
    private func highlightedRunCount(_ attributed: AttributedString) -> Int {
        attributed.runs.filter { $0.foregroundColor == Color.accentColor }.count
    }

    /// Concatenates the characters of all highlighted runs.
    private func highlightedText(_ attributed: AttributedString) -> String {
        attributed.runs
            .filter { $0.foregroundColor == Color.accentColor }
            .map { String(attributed[$0.range].characters) }
            .joined()
    }

    func testEmptyNeedleHighlightsNothing() {
        let result = highlightOccurrences(of: "", in: "hello world")
        XCTAssertEqual(highlightedRunCount(result), 0)
        XCTAssertEqual(String(result.characters), "hello world")
    }

    func testNoMatchHighlightsNothing() {
        let result = highlightOccurrences(of: "xyz", in: "hello world")
        XCTAssertEqual(highlightedRunCount(result), 0)
    }

    func testSingleMatchIsHighlighted() {
        let result = highlightOccurrences(of: "world", in: "hello world")
        XCTAssertEqual(highlightedText(result), "world")
    }

    func testAllOccurrencesAreHighlighted() {
        let result = highlightOccurrences(of: "an", in: "banana and an ananas")
        // "banana" (2: b[an][an]a) + "and"(an) + " an " (an) + "ananas"(an)
        // Count the highlighted runs: every "an" substring should be tinted.
        XCTAssertEqual(highlightedText(result), String(repeating: "an", count: highlightedRunCount(result)))
        XCTAssertGreaterThanOrEqual(highlightedRunCount(result), 4)
    }

    func testCaseInsensitiveMatching() {
        let result = highlightOccurrences(of: "hello", in: "Hello HELLO hello")
        XCTAssertEqual(highlightedRunCount(result), 3)
        // Original casing is preserved in the output.
        XCTAssertEqual(String(result.characters), "Hello HELLO hello")
    }

    func testEmptyTextYieldsEmpty() {
        let result = highlightOccurrences(of: "x", in: "")
        XCTAssertEqual(String(result.characters), "")
        XCTAssertEqual(highlightedRunCount(result), 0)
    }
}
