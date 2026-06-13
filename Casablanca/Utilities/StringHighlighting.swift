import SwiftUI

/// Returns an `AttributedString` of `text` with every case-insensitive
/// occurrence of `needle` emphasized (accent color + semibold). Non-matching
/// runs keep the default attributes.
///
/// Pure and side-effect free so it can be unit-tested. An empty `needle` (or a
/// needle that doesn't occur) yields the plain text unchanged.
func highlightOccurrences(of needle: String, in text: String) -> AttributedString {
    var attributed = AttributedString(text)

    let trimmedNeedle = needle
    guard !trimmedNeedle.isEmpty, !text.isEmpty else { return attributed }

    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let range = text.range(
              of: trimmedNeedle,
              options: .caseInsensitive,
              range: searchStart..<text.endIndex
          ) {
        if let attrRange = Range(range, in: attributed) {
            attributed[attrRange].foregroundColor = Color.accentColor
            attributed[attrRange].font = .body.weight(.semibold)
        }
        // Advance past this match. Guard against zero-width loops.
        if range.upperBound > searchStart {
            searchStart = range.upperBound
        } else {
            searchStart = text.index(after: searchStart)
        }
    }

    return attributed
}
