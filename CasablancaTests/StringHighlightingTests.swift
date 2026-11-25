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
        // Mix of ADJACENT matches ("banana": b[an][an]a, "ananas": [an]anas — note
        // only the first "an" of "ananas" matches because search advances past it)
        // and SEPARATED matches ("and", standalone "an"). Adjacent matches coalesce
        // into one AttributedString run (identical attributes), so run-count is NOT
        // occurrence-count. The robust invariant: the exact character positions of
        // every occurrence carry the highlight, i.e. the highlighted-character total
        // equals occurrences × needle.count, and the highlighted ranges are precisely
        // the occurrence ranges in the source.
        let text = "banana and an ananas"
        let needle = "an"
        let result = highlightOccurrences(of: needle, in: text)

        // Compute the expected occurrence ranges the production code visits:
        // case-insensitive, non-overlapping, scanning left-to-right.
        var expectedRanges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            expectedRanges.append(range)
            searchStart = range.upperBound > searchStart ? range.upperBound : text.index(after: searchStart)
        }

        // Sanity: this fixture must contain both adjacent and separated matches.
        XCTAssertGreaterThanOrEqual(expectedRanges.count, 5)

        // 1) Highlighted-character count equals occurrences × needle.count.
        let highlightedCharCount = highlightedText(result).count
        XCTAssertEqual(highlightedCharCount, expectedRanges.count * needle.count)

        // 2) Every occurrence position carries the highlight, and nothing else does.
        // Walk the AttributedString character-by-character in lockstep with the
        // source string by offset.
        let characters = result.characters
        var offset = 0
        var charIndex = characters.startIndex
        while charIndex < characters.endIndex {
            let stringIndex = text.index(text.startIndex, offsetBy: offset)
            let isOccurrence = expectedRanges.contains { $0.contains(stringIndex) }
            let nextIndex = characters.index(after: charIndex)
            let isHighlighted = result[charIndex..<nextIndex].foregroundColor == Color.accentColor
            XCTAssertEqual(isHighlighted, isOccurrence,
                           "Character '\(characters[charIndex])' at offset \(offset) highlight mismatch")
            charIndex = nextIndex
            offset += 1
        }
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
