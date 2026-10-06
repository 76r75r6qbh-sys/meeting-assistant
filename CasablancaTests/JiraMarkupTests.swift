// CasablancaTests/JiraMarkupTests.swift
import XCTest
@testable import Casablanca

/// Tests for the pure `parseJiraMarkup` parser (no SwiftUI involved).
final class JiraMarkupTests: XCTestCase {

    // MARK: - Headings

    func test_headings_allLevels() {
        for level in 1...6 {
            let blocks = parseJiraMarkup("h\(level). Title \(level)")
            XCTAssertEqual(blocks, [.heading(level: level, [.text("Title \(level)")])])
        }
    }

    func test_heading_requiresSpaceAfterDot() {
        // "h1.text" without a space is not a heading — it degrades to a paragraph.
        let blocks = parseJiraMarkup("h1.text")
        XCTAssertEqual(blocks, [.paragraph([.text("h1.text")])])
    }

    func test_heading_level7_isNotHeading() {
        let blocks = parseJiraMarkup("h7. Nope")
        XCTAssertEqual(blocks, [.paragraph([.text("h7. Nope")])])
    }

    // MARK: - Inline: bold / italic / code / link

    func test_inline_bold() {
        let blocks = parseJiraMarkup("a *bold* b")
        XCTAssertEqual(blocks, [.paragraph([
            .text("a "),
            .bold([.text("bold")]),
            .text(" b"),
        ])])
    }

    func test_inline_italic() {
        let blocks = parseJiraMarkup("a _it_ b")
        XCTAssertEqual(blocks, [.paragraph([
            .text("a "),
            .italic([.text("it")]),
            .text(" b"),
        ])])
    }

    func test_inline_code() {
        let blocks = parseJiraMarkup("call {{foo()}} now")
        XCTAssertEqual(blocks, [.paragraph([
            .text("call "),
            .code("foo()"),
            .text(" now"),
        ])])
    }

    func test_inline_link_textAndUrl() {
        let blocks = parseJiraMarkup("see [Docs|https://example.com] here")
        XCTAssertEqual(blocks, [.paragraph([
            .text("see "),
            .link(text: "Docs", url: "https://example.com"),
            .text(" here"),
        ])])
    }

    func test_inline_link_bareUrl() {
        let blocks = parseJiraMarkup("[https://example.com]")
        XCTAssertEqual(blocks, [.paragraph([
            .link(text: "https://example.com", url: "https://example.com"),
        ])])
    }

    func test_inline_nestedBoldInsideItalic() {
        let blocks = parseJiraMarkup("_a *b* c_")
        XCTAssertEqual(blocks, [.paragraph([
            .italic([
                .text("a "),
                .bold([.text("b")]),
                .text(" c"),
            ]),
        ])])
    }

    // MARK: - Code block

    func test_codeBlock_verbatim_markupNotInterpreted() {
        let input = """
        {code:java}
        if (*x*) {
          return [a|b];
        }
        {code}
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [.codeBlock("if (*x*) {\n  return [a|b];\n}")])
    }

    func test_codeBlock_plain() {
        let input = """
        {code}
        line one
        line two
        {code}
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [.codeBlock("line one\nline two")])
    }

    func test_codeBlock_unterminated_degradesToText() {
        let input = """
        {code}
        orphan
        """
        let blocks = parseJiraMarkup(input)
        // No closing fence: content is preserved as paragraphs, not swallowed.
        XCTAssertEqual(blocks, [.paragraph([.text("{code}\norphan")])])
    }

    // MARK: - Lists

    func test_bulletList() {
        let input = """
        * one
        * two
        * three
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [.bulletList([
            [.text("one")],
            [.text("two")],
            [.text("three")],
        ])])
    }

    func test_numberedList() {
        let input = """
        # alpha
        # beta
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [.numberedList([
            [.text("alpha")],
            [.text("beta")],
        ])])
    }

    func test_bulletList_nestedFlattened() {
        let input = """
        * top
        ** nested
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [.bulletList([
            [.text("top")],
            [.text("nested")],
        ])])
    }

    // MARK: - Table

    func test_table_headerAndTwoRows() {
        let input = """
        ||Name||Role||
        |Youri|PO|
        |Marcel|CTO|
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [.table(
            headers: [[.text("Name")], [.text("Role")]],
            rows: [
                [[.text("Youri")], [.text("PO")]],
                [[.text("Marcel")], [.text("CTO")]],
            ]
        )])
    }

    func test_table_cellsParseInline() {
        let input = """
        ||H||
        |*bold*|
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [.table(
            headers: [[.text("H")]],
            rows: [
                [[.bold([.text("bold")])]],
            ]
        )])
    }

    // MARK: - Unbalanced / unknown markup

    func test_loneAsterisk_isLiteral() {
        let blocks = parseJiraMarkup("2 * 3 = 6")
        XCTAssertEqual(blocks, [.paragraph([.text("2 * 3 = 6")])])
    }

    func test_unclosedBracket_isLiteral() {
        let blocks = parseJiraMarkup("see [unclosed here")
        XCTAssertEqual(blocks, [.paragraph([.text("see [unclosed here")])])
    }

    func test_unclosedInlineCode_isLiteral() {
        let blocks = parseJiraMarkup("call {{foo")
        XCTAssertEqual(blocks, [.paragraph([.text("call {{foo")])])
    }

    func test_emptyEmphasis_isLiteral() {
        // "**" should not become an empty bold; the markers stay literal.
        let blocks = parseJiraMarkup("a ** b")
        XCTAssertEqual(blocks, [.paragraph([.text("a ** b")])])
    }

    // MARK: - Paragraph separation

    func test_blankLineSeparatesParagraphs() {
        let input = """
        first

        second
        """
        let blocks = parseJiraMarkup(input)
        XCTAssertEqual(blocks, [
            .paragraph([.text("first")]),
            .paragraph([.text("second")]),
        ])
    }

    // MARK: - CRLF normalization

    func test_crlf_parsesSameAsLf() {
        let lf = "h1. Title\n\nbody *x*"
        let crlf = "h1. Title\r\n\r\nbody *x*"
        XCTAssertEqual(parseJiraMarkup(crlf), parseJiraMarkup(lf))
    }

    func test_cr_only_parsesSameAsLf() {
        let lf = "* a\n* b"
        let cr = "* a\r* b"
        XCTAssertEqual(parseJiraMarkup(cr), parseJiraMarkup(lf))
    }

    // MARK: - Degrade-gracefully consistency (review fixes)

    func test_malformedURL_degradesToLiteralText() {
        // A URL that does not parse must not produce a dead `.link`; the visible
        // text is kept as literal instead.
        let blocks = parseJiraMarkup("see [click here|http://a b]")
        XCTAssertEqual(blocks, [.paragraph([.text("see "), .text("click here")])])
    }

    func test_validURL_stillProducesLink() {
        let blocks = parseJiraMarkup("[IO-1|https://jira/IO-1]")
        XCTAssertEqual(blocks, [.paragraph([.link(text: "IO-1", url: "https://jira/IO-1")])])
    }

    func test_table_secondHeaderRowBecomesBodyRowNotDropped() {
        // Only the first ||..|| row defines headers; a later one is demoted to a
        // body row so its content is never silently dropped.
        let blocks = parseJiraMarkup("||A||B||\n|1|2|\n||C||D||")
        XCTAssertEqual(blocks, [
            .table(
                headers: [[.text("A")], [.text("B")]],
                rows: [
                    [[.text("1")], [.text("2")]],
                    [[.text("C")], [.text("D")]],
                ]
            )
        ])
    }
}
