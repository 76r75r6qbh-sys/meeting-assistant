import AppKit
import XCTest
@testable import Casablanca

final class NativeMarkdownEditorTests: XCTestCase {

    // MARK: - Heading detection

    func testHeadingLevels() {
        XCTAssertEqual(MarkdownSyntaxStyling.headingLevel(for: "# Title"), 1)
        XCTAssertEqual(MarkdownSyntaxStyling.headingLevel(for: "## Sub"), 2)
        XCTAssertEqual(MarkdownSyntaxStyling.headingLevel(for: "###### Deep"), 6)
        XCTAssertNil(MarkdownSyntaxStyling.headingLevel(for: "#NoSpace"))
        XCTAssertNil(MarkdownSyntaxStyling.headingLevel(for: "####### TooDeep"))
        XCTAssertNil(MarkdownSyntaxStyling.headingLevel(for: "plain"))
    }

    func testHeadingSpanCoversWholeLine() {
        let line = "## Heading"
        let spans = MarkdownSyntaxStyling.spans(for: line)
        guard let heading = spans.first(where: { if case .heading = $0.kind { return true } else { return false } }) else {
            return XCTFail("expected heading span")
        }
        XCTAssertEqual(heading.range, NSRange(location: 0, length: (line as NSString).length))
    }

    // MARK: - List markers

    func testUnorderedListMarker() {
        XCTAssertEqual(MarkdownSyntaxStyling.listMarkerLength(for: "- item"), 2)
        XCTAssertEqual(MarkdownSyntaxStyling.listMarkerLength(for: "* item"), 2)
    }

    func testOrderedListMarker() {
        XCTAssertEqual(MarkdownSyntaxStyling.listMarkerLength(for: "1. item"), 3)
        XCTAssertEqual(MarkdownSyntaxStyling.listMarkerLength(for: "12. item"), 4)
    }

    func testBoldIsNotListMarker() {
        // "**bold**" starts with "* " ? No — "**" has no space, so not a list.
        XCTAssertNil(MarkdownSyntaxStyling.listMarkerLength(for: "**bold**"))
    }

    func testListMarkerSpanOnLine() {
        let spans = MarkdownSyntaxStyling.spans(for: "- task")
        XCTAssertTrue(spans.contains(MarkdownStyleSpan(range: NSRange(location: 0, length: 2), kind: .listMarker)))
    }

    // MARK: - Inline spans

    func testBoldSpanRange() {
        let line = "say **hi** now"
        let spans = MarkdownSyntaxStyling.inlineSpans(for: line)
        let bold = spans.filter { $0.kind == .bold }
        XCTAssertEqual(bold.count, 1)
        // "**hi**" begins at index 4, length 6.
        XCTAssertEqual(bold.first?.range, NSRange(location: 4, length: 6))
    }

    func testCodeSpanRange() {
        let line = "use `code` here"
        let spans = MarkdownSyntaxStyling.inlineSpans(for: line)
        let code = spans.filter { $0.kind == .code }
        XCTAssertEqual(code.count, 1)
        XCTAssertEqual(code.first?.range, NSRange(location: 4, length: 6))
    }

    func testItalicSpanRequiresWordBoundary() {
        // Surrounded by spaces -> italic.
        let italic = MarkdownSyntaxStyling.inlineSpans(for: "an _emphasis_ word").filter { $0.kind == .italic }
        XCTAssertEqual(italic.count, 1)
        XCTAssertEqual(italic.first?.range, NSRange(location: 3, length: 10))

        // snake_case inside a word -> not italic.
        let none = MarkdownSyntaxStyling.inlineSpans(for: "my_var_name").filter { $0.kind == .italic }
        XCTAssertTrue(none.isEmpty)
    }

    func testEmptyBoldTokenProducesNoSpan() {
        let spans = MarkdownSyntaxStyling.inlineSpans(for: "****").filter { $0.kind == .bold }
        XCTAssertTrue(spans.isEmpty)
    }

    func testMultipleBoldSpans() {
        let line = "**a** and **b**"
        let bold = MarkdownSyntaxStyling.inlineSpans(for: line).filter { $0.kind == .bold }
        XCTAssertEqual(bold.count, 2)
        XCTAssertEqual(bold[0].range, NSRange(location: 0, length: 5))
        XCTAssertEqual(bold[1].range, NSRange(location: 10, length: 5))
    }

    // MARK: - Selection-aware applyMarkdown

    func testWrapSelectionBold() {
        // Wrap "lo" in "hello" -> "hel**lo**" with content "lo" still selected.
        let text = "hello"
        let selection = NSRange(location: 3, length: 2) // "lo"
        let result = MarkdownSelectionEditing.apply(.bold, to: text, selectedRange: selection)
        XCTAssertEqual(result.text, "hel**lo**")
        XCTAssertEqual(result.selectedRange, NSRange(location: 5, length: 2))
        // Sanity: the selected substring is the original content.
        XCTAssertEqual((result.text as NSString).substring(with: result.selectedRange), "lo")
    }

    func testWrapSelectionItalic() {
        let result = MarkdownSelectionEditing.apply(.italic, to: "hello", selectedRange: NSRange(location: 0, length: 5))
        XCTAssertEqual(result.text, "_hello_")
        XCTAssertEqual(result.selectedRange, NSRange(location: 1, length: 5))
    }

    func testInsertAtCaretPlacesCursorBetweenMarkers() {
        let result = MarkdownSelectionEditing.apply(.bold, to: "ab", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(result.text, "a****b")
        XCTAssertEqual(result.selectedRange, NSRange(location: 3, length: 0))
    }

    func testCodeWrap() {
        let result = MarkdownSelectionEditing.apply(.code, to: "run x", selectedRange: NSRange(location: 4, length: 1))
        XCTAssertEqual(result.text, "run `x`")
        XCTAssertEqual(result.selectedRange, NSRange(location: 5, length: 1))
    }

    func testHeadingPrefixSingleLine() {
        let result = MarkdownSelectionEditing.apply(.heading, to: "Title", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(result.text, "## Title")
    }

    func testListPrefixMultiLine() {
        let text = "one\ntwo\nthree"
        // Selection spanning lines 1 and 2.
        let selection = NSRange(location: 0, length: 7) // "one\ntwo"
        let result = MarkdownSelectionEditing.apply(.list, to: text, selectedRange: selection)
        XCTAssertEqual(result.text, "- one\n- two\nthree")
    }

    func testHeadingPrefixIsIdempotentPerLine() {
        let result = MarkdownSelectionEditing.apply(.heading, to: "## Already", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(result.text, "## Already")
    }

    // MARK: - Storage delegate styling (integration of pure ranges + AppKit)

    func testStorageDelegateAppliesHeadingFont() {
        let base = NSFont.systemFont(ofSize: 15)
        let delegate = MarkdownStylingTextStorageDelegate(baseFont: base)
        let storage = NSTextStorage(string: "# Big")
        storage.delegate = delegate
        delegate.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length))

        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font!.pointSize, base.pointSize)
    }

    func testStorageDelegateTintsListMarker() {
        let delegate = MarkdownStylingTextStorageDelegate(baseFont: .systemFont(ofSize: 15))
        let storage = NSTextStorage(string: "- item")
        storage.delegate = delegate
        delegate.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length))

        let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.controlAccentColor)
    }
}
