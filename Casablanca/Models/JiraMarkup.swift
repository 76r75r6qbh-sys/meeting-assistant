import Foundation

// MARK: - AST

/// A single inline run within a block of Jira markup.
///
/// Inline runs are produced by `parseInline(_:)`. Any marker that cannot be
/// balanced (e.g. a lone `*` or an unclosed `[`) degrades to `.text` so that no
/// source content is ever dropped.
indirect enum JiraInline: Equatable {
    case text(String)
    case bold([JiraInline])
    case italic([JiraInline])
    case code(String)
    case link(text: String, url: String)
}

/// A top-level block produced by `parseJiraMarkup(_:)`.
enum JiraBlock: Equatable {
    case heading(level: Int, [JiraInline])
    case paragraph([JiraInline])
    case bulletList([[JiraInline]])
    case numberedList([[JiraInline]])
    case codeBlock(String)
    case table(headers: [[JiraInline]], rows: [[[JiraInline]]])
}

// MARK: - Entry point

/// Parses a Jira wiki-markup string into a typed block AST.
///
/// The parser is intentionally forgiving: unknown or unbalanced markup degrades
/// to literal text rather than throwing or dropping content. CRLF/CR line
/// endings are normalized to LF at this boundary.
func parseJiraMarkup(_ s: String) -> [JiraBlock] {
    let normalized = s
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    let lines = normalized.components(separatedBy: "\n")
    var blocks: [JiraBlock] = []

    // Accumulator for consecutive plain text lines that form one paragraph.
    var paragraphLines: [String] = []

    func flushParagraph() {
        guard !paragraphLines.isEmpty else { return }
        // Join wrapped lines with a space; the joined text is parsed for inline markup.
        let joined = paragraphLines.joined(separator: "\n")
        paragraphLines.removeAll(keepingCapacity: true)
        blocks.append(.paragraph(parseInline(joined)))
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Blank line: separates paragraphs.
        if trimmed.isEmpty {
            flushParagraph()
            i += 1
            continue
        }

        // Code block: {code} ... {code} (or {code:lang}). Spans lines verbatim.
        if isCodeFenceOpener(trimmed) {
            flushParagraph()
            var body: [String] = []
            var j = i + 1
            var closed = false
            while j < lines.count {
                if lines[j].trimmingCharacters(in: .whitespaces) == "{code}" {
                    closed = true
                    break
                }
                body.append(lines[j])
                j += 1
            }
            if closed {
                blocks.append(.codeBlock(body.joined(separator: "\n")))
                i = j + 1
                continue
            }
            // Unterminated fence: degrade to literal text, do not consume the rest
            // of the document as a code block.
            paragraphLines.append(line)
            i += 1
            continue
        }

        // Heading: h1. … h6. followed by a space.
        if let (level, content) = parseHeading(trimmed) {
            flushParagraph()
            blocks.append(.heading(level: level, parseInline(content)))
            i += 1
            continue
        }

        // Table: a run of lines that are header (||..||) or body (|..|) rows.
        if isTableRow(trimmed) {
            flushParagraph()
            var headers: [[JiraInline]] = []
            var rows: [[[JiraInline]]] = []
            var j = i
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                guard isTableRow(t) else { break }
                if isHeaderRow(t) && headers.isEmpty && rows.isEmpty {
                    // Only the first row may define headers. A later ||..|| row is
                    // treated as a body row so its content is never dropped.
                    headers = parseTableCells(t, separator: "||")
                } else {
                    // A doubled-pipe row demoted to a body row still splits on "||".
                    rows.append(parseTableCells(t, separator: isHeaderRow(t) ? "||" : "|"))
                }
                j += 1
            }
            blocks.append(.table(headers: headers, rows: rows))
            i = j
            continue
        }

        // Bullet list: a run of lines starting with "* " (or nested "** ").
        if isBulletItem(trimmed) {
            flushParagraph()
            var items: [[JiraInline]] = []
            var j = i
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                guard isBulletItem(t) else { break }
                items.append(parseInline(bulletContent(t)))
                j += 1
            }
            blocks.append(.bulletList(items))
            i = j
            continue
        }

        // Numbered list: a run of lines starting with "# " (or nested "## ").
        if isNumberedItem(trimmed) {
            flushParagraph()
            var items: [[JiraInline]] = []
            var j = i
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                guard isNumberedItem(t) else { break }
                items.append(parseInline(numberedContent(t)))
                j += 1
            }
            blocks.append(.numberedList(items))
            i = j
            continue
        }

        // Plain text line: accumulate into the current paragraph.
        paragraphLines.append(line)
        i += 1
    }

    flushParagraph()
    return blocks
}

// MARK: - Block helpers

private func isCodeFenceOpener(_ trimmed: String) -> Bool {
    trimmed == "{code}" || trimmed.hasPrefix("{code:") && trimmed.hasSuffix("}")
}

/// Returns `(level, content)` if the line is a `hN.` heading, else `nil`.
private func parseHeading(_ trimmed: String) -> (Int, String)? {
    guard trimmed.count >= 4, trimmed.first == "h" else { return nil }
    let chars = Array(trimmed)
    guard let digit = chars[1].wholeNumberValue, (1...6).contains(digit) else { return nil }
    guard chars[2] == "." else { return nil }
    // Require a space after the dot (so "h1.text" is not a heading).
    guard chars[3] == " " else { return nil }
    let content = String(chars[4...]).trimmingCharacters(in: .whitespaces)
    return (digit, content)
}

private func isTableRow(_ trimmed: String) -> Bool {
    trimmed.hasPrefix("|") && trimmed.count >= 2
}

private func isHeaderRow(_ trimmed: String) -> Bool {
    trimmed.hasPrefix("||")
}

/// Splits a table row on the cell separator, trimming the leading/trailing
/// separators and parsing each cell's inline content.
private func parseTableCells(_ trimmed: String, separator: String) -> [[JiraInline]] {
    var body = trimmed
    // Strip a leading separator.
    if body.hasPrefix(separator) {
        body.removeFirst(separator.count)
    } else if body.hasPrefix("|") {
        body.removeFirst()
    }
    // Strip a trailing separator.
    if body.hasSuffix(separator) {
        body.removeLast(separator.count)
    } else if body.hasSuffix("|") {
        body.removeLast()
    }
    let rawCells = body.components(separatedBy: separator)
    return rawCells.map { parseInline($0.trimmingCharacters(in: .whitespaces)) }
}

private func isBulletItem(_ trimmed: String) -> Bool {
    // "* x" or nested "** x" — at least one "*" then a space.
    guard trimmed.hasPrefix("*") else { return false }
    let afterStars = trimmed.drop(while: { $0 == "*" })
    return afterStars.first == " "
}

private func bulletContent(_ trimmed: String) -> String {
    String(trimmed.drop(while: { $0 == "*" })).trimmingCharacters(in: .whitespaces)
}

private func isNumberedItem(_ trimmed: String) -> Bool {
    guard trimmed.hasPrefix("#") else { return false }
    let afterHashes = trimmed.drop(while: { $0 == "#" })
    return afterHashes.first == " "
}

private func numberedContent(_ trimmed: String) -> String {
    String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
}

// MARK: - Inline parsing

/// Parses inline Jira markup left-to-right. Any marker without a matching closer
/// is emitted as literal text so content is never dropped.
func parseInline(_ s: String) -> [JiraInline] {
    var result: [JiraInline] = []
    let chars = Array(s)
    var i = 0
    var literal = ""

    func flushLiteral() {
        if !literal.isEmpty {
            result.append(.text(literal))
            literal = ""
        }
    }

    while i < chars.count {
        let c = chars[i]

        switch c {
        case "{":
            // Inline code: {{text}}
            if i + 1 < chars.count, chars[i + 1] == "{" {
                if let closeStart = findCloser(chars, from: i + 2, marker: "}}") {
                    flushLiteral()
                    let inner = String(chars[(i + 2)..<closeStart])
                    result.append(.code(inner))
                    i = closeStart + 2
                    continue
                }
            }
            literal.append(c)
            i += 1

        case "*":
            // Bold: *text* — must have a matching closing "*".
            if let close = findInlineCloser(chars, from: i + 1, marker: "*") {
                flushLiteral()
                let inner = String(chars[(i + 1)..<close])
                result.append(.bold(parseInline(inner)))
                i = close + 1
                continue
            }
            literal.append(c)
            i += 1

        case "_":
            // Italic: _text_
            if let close = findInlineCloser(chars, from: i + 1, marker: "_") {
                flushLiteral()
                let inner = String(chars[(i + 1)..<close])
                result.append(.italic(parseInline(inner)))
                i = close + 1
                continue
            }
            literal.append(c)
            i += 1

        case "[":
            // Link: [text|url] or bare [url]
            if let close = findCharCloser(chars, from: i + 1, char: "]") {
                let inner = String(chars[(i + 1)..<close])
                if !inner.isEmpty {
                    flushLiteral()
                    let text: String
                    let url: String
                    if let pipe = inner.firstIndex(of: "|") {
                        text = String(inner[inner.startIndex..<pipe])
                        url = String(inner[inner.index(after: pipe)...])
                    } else {
                        text = inner
                        url = inner
                    }
                    // Keep the AST honest: only emit `.link` for a URL that
                    // actually parses; otherwise degrade the visible text to
                    // literal so the view never claims a dead link.
                    if URL(string: url) != nil {
                        result.append(.link(text: text, url: url))
                    } else {
                        result.append(.text(text))
                    }
                    i = close + 1
                    continue
                }
            }
            literal.append(c)
            i += 1

        default:
            literal.append(c)
            i += 1
        }
    }

    flushLiteral()
    return result
}

/// Finds the index where a multi-character `marker` begins, scanning forward
/// from `from`. Returns `nil` if no occurrence exists.
private func findCloser(_ chars: [Character], from: Int, marker: String) -> Int? {
    let m = Array(marker)
    guard !m.isEmpty else { return nil }
    var i = from
    while i + m.count <= chars.count {
        if Array(chars[i..<(i + m.count)]) == m {
            return i
        }
        i += 1
    }
    return nil
}

/// Finds a single closing `char`, scanning forward from `from`.
private func findCharCloser(_ chars: [Character], from: Int, char: Character) -> Int? {
    var i = from
    while i < chars.count {
        if chars[i] == char { return i }
        i += 1
    }
    return nil
}

/// Finds the closing single-character `marker` for an emphasis run. Requires a
/// non-empty inner span (so `**` does not parse as empty bold) and stops at the
/// first matching marker.
private func findInlineCloser(_ chars: [Character], from: Int, marker: Character) -> Int? {
    guard from < chars.count else { return nil }
    // Empty span (marker immediately follows) is not valid emphasis.
    if chars[from] == marker { return nil }
    var i = from
    while i < chars.count {
        if chars[i] == marker { return i }
        i += 1
    }
    return nil
}
