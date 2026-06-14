import SwiftUI

/// Renders a Jira wiki-markup string as formatted SwiftUI content.
///
/// Parsing is delegated to the pure `parseJiraMarkup(_:)` parser; this view only
/// concerns itself with presentation. Inline runs are flattened into a single
/// `AttributedString` per paragraph/heading so emphasis, inline code and links
/// compose cleanly (including tappable links).
struct JiraMarkupText: View {
    let markup: String

    private var blocks: [JiraBlock] { parseJiraMarkup(markup) }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: JiraBlock) -> some View {
        switch block {
        case let .heading(level, inlines):
            Text(attributed(inlines))
                .font(headingFont(level: level))
                .fontWeight(.bold)

        case let .paragraph(inlines):
            Text(attributed(inlines))
                .textSelection(.enabled)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(prefix: "•", inlines: item)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    listRow(prefix: "\(idx + 1).", inlines: item)
                }
            }

        case let .codeBlock(code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CasaSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: CasaRadius.md)
                        .fill(Color.secondary.opacity(0.1))
                )

        case let .table(headers, rows):
            tableView(headers: headers, rows: rows)
        }
    }

    @ViewBuilder
    private func listRow(prefix: String, inlines: [JiraInline]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Text(prefix)
                .foregroundStyle(.secondary)
            Text(attributed(inlines))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func tableView(headers: [[JiraInline]], rows: [[[JiraInline]]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: CasaSpace.md, verticalSpacing: CasaSpace.sm) {
            if !headers.isEmpty {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(attributed(col < headers.count ? headers[col] : []))
                            .fontWeight(.semibold)
                    }
                }
                Divider()
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(attributed(col < row.count ? row[col] : []))
                    }
                }
                if rowIdx < rows.count - 1 {
                    Divider()
                }
            }
        }
        .padding(CasaSpace.sm)
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.md)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        case 5: return .subheadline
        default: return .footnote
        }
    }

    // MARK: - Inline -> AttributedString

    /// Builds a single `AttributedString` for a run of inline elements, applying
    /// bold/italic intents, monospaced inline code and tappable link URLs.
    private func attributed(_ inlines: [JiraInline]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(attributed(inline))
        }
        return result
    }

    private func attributed(_ inline: JiraInline) -> AttributedString {
        switch inline {
        case let .text(s):
            return AttributedString(s)

        case let .bold(children):
            var s = attributed(children)
            s.inlinePresentationIntent = (s.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            return s

        case let .italic(children):
            var s = attributed(children)
            s.inlinePresentationIntent = (s.inlinePresentationIntent ?? []).union(.emphasized)
            return s

        case let .code(text):
            var s = AttributedString(text)
            s.inlinePresentationIntent = .code
            s.font = .system(.body, design: .monospaced)
            return s

        case let .link(text, url):
            var s = AttributedString(text)
            if let parsed = URL(string: url) {
                s.link = parsed
                s.foregroundColor = .accentColor
                s.underlineStyle = .single
            }
            return s
        }
    }
}

#if DEBUG
#Preview {
    ScrollView {
        JiraMarkupText(markup: """
        h1. Heading One
        h3. Smaller Heading

        This is a paragraph with *bold*, _italic_, {{inline code}} and a [link|https://example.com].

        * first bullet
        * second bullet with *bold*

        # first numbered
        # second numbered

        {code:java}
        let x = *not bold*
        print(x)
        {code}

        ||Name||Role||
        |Youri|PO|
        |Marcel|CTO|
        """)
        .padding()
    }
    .frame(width: 480, height: 600)
}
#endif
