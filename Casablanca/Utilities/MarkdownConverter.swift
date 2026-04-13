import AppKit

enum MarkdownConverter {

    // MARK: Markdown -> NSAttributedString

    static func markdownToAttributedString(_ markdown: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        let fm = NSFontManager.shared

        for (index, line) in lines.enumerated() {
            var processedLine = line
            var paragraphPrefix = ""
            var lineBaseFont = baseFont

            if processedLine.hasPrefix("# ") {
                processedLine = String(processedLine.dropFirst(2))
                lineBaseFont = .systemFont(ofSize: baseFont.pointSize + 8, weight: .bold)
            } else if processedLine.hasPrefix("## ") {
                processedLine = String(processedLine.dropFirst(3))
                lineBaseFont = .systemFont(ofSize: baseFont.pointSize + 4, weight: .bold)
            } else if processedLine.hasPrefix("### ") {
                processedLine = String(processedLine.dropFirst(4))
                lineBaseFont = .systemFont(ofSize: baseFont.pointSize + 2, weight: .bold)
            }

            if processedLine.hasPrefix("- ") {
                processedLine = String(processedLine.dropFirst(2))
                paragraphPrefix = "•\t"
            } else if processedLine.hasPrefix("* ") && !processedLine.hasPrefix("**") {
                processedLine = String(processedLine.dropFirst(2))
                paragraphPrefix = "•\t"
            }

            if let match = processedLine.prefixMatch(of: /^(\d+)\.\s/) {
                processedLine = String(processedLine[match.range.upperBound...])
                paragraphPrefix = "\(match.1).\t"
            }

            let attributed = parseInlineFormatting(processedLine, baseFont: lineBaseFont, fontManager: fm)

            if !paragraphPrefix.isEmpty {
                let prefixAttrs: [NSAttributedString.Key: Any] = [
                    .font: lineBaseFont,
                    .foregroundColor: NSColor.labelColor,
                ]
                let prefixString = NSAttributedString(string: paragraphPrefix, attributes: prefixAttrs)
                let combined = NSMutableAttributedString()
                combined.append(prefixString)
                combined.append(attributed)
                result.append(combined)
            } else {
                result.append(attributed)
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: lineBaseFont]))
            }
        }

        return result
    }

    private static func parseInlineFormatting(
        _ text: String,
        baseFont: NSFont,
        fontManager fm: NSFontManager
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var index = text.startIndex
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        while index < text.endIndex {
            if text[index...].hasPrefix("***"),
               let endRange = text[text.index(index, offsetBy: 3)...].range(of: "***")
            {
                let contentStart = text.index(index, offsetBy: 3)
                let content = String(text[contentStart..<endRange.lowerBound])
                let boldItalicFont = fm.convert(fm.convert(baseFont, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask)
                var attrs = baseAttributes
                attrs[.font] = boldItalicFont
                result.append(NSAttributedString(string: content, attributes: attrs))
                index = endRange.upperBound
                continue
            }

            if text[index...].hasPrefix("**"),
               let endRange = text[text.index(index, offsetBy: 2)...].range(of: "**")
            {
                let contentStart = text.index(index, offsetBy: 2)
                let content = String(text[contentStart..<endRange.lowerBound])
                let boldFont = fm.convert(baseFont, toHaveTrait: .boldFontMask)
                var attrs = baseAttributes
                attrs[.font] = boldFont
                result.append(NSAttributedString(string: content, attributes: attrs))
                index = endRange.upperBound
                continue
            }

            if text[index...].hasPrefix("*") && !text[index...].hasPrefix("**") {
                let searchStart = text.index(after: index)
                if searchStart < text.endIndex,
                   let endIndex = text[searchStart...].firstIndex(of: "*")
                {
                    let content = String(text[searchStart..<endIndex])
                    if !content.isEmpty && !content.hasPrefix(" ") && !content.hasSuffix(" ") {
                        let italicFont = fm.convert(baseFont, toHaveTrait: .italicFontMask)
                        var attrs = baseAttributes
                        attrs[.font] = italicFont
                        result.append(NSAttributedString(string: content, attributes: attrs))
                        index = text.index(after: endIndex)
                        continue
                    }
                }
            }

            if text[index...].hasPrefix("~~") {
                let searchStart = text.index(index, offsetBy: 2)
                if searchStart < text.endIndex,
                   let endRange = text[searchStart...].range(of: "~~")
                {
                    let content = String(text[searchStart..<endRange.lowerBound])
                    var attrs = baseAttributes
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    result.append(NSAttributedString(string: content, attributes: attrs))
                    index = endRange.upperBound
                    continue
                }
            }

            if text[index...].hasPrefix("<u>") {
                let searchStart = text.index(index, offsetBy: 3)
                if searchStart < text.endIndex,
                   let endRange = text[searchStart...].range(of: "</u>")
                {
                    let content = String(text[searchStart..<endRange.lowerBound])
                    var attrs = baseAttributes
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    result.append(NSAttributedString(string: content, attributes: attrs))
                    index = endRange.upperBound
                    continue
                }
            }

            result.append(NSAttributedString(string: String(text[index]), attributes: baseAttributes))
            index = text.index(after: index)
        }

        return result
    }

    // MARK: NSAttributedString -> Markdown

    static func attributedStringToMarkdown(_ storage: NSAttributedString, baseFont: NSFont) -> String {
        let string = storage.string
        guard !string.isEmpty else { return "" }

        var result = ""
        let fm = NSFontManager.shared
        let nsString = string as NSString
        var lineStart = 0

        while lineStart < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: lineStart, length: 0))
            var lineText = nsString.substring(with: lineRange)
            let hasNewline = lineText.hasSuffix("\n")

            if hasNewline {
                lineText = String(lineText.dropLast())
            }

            var markdownPrefix = ""
            var contentOffset = 0
            if lineText.hasPrefix("•\t") || lineText.hasPrefix("• ") {
                markdownPrefix = "- "
                contentOffset = 2
            } else if let match = lineText.prefixMatch(of: /^(\d+)\.\t/) {
                markdownPrefix = "\(match.1). "
                contentOffset = match.0.count
            }

            let contentRange = NSRange(
                location: lineRange.location + contentOffset,
                length: max(0, lineText.count - contentOffset)
            )

            var lineMarkdown = ""
            if contentRange.length > 0 && contentRange.location + contentRange.length <= storage.length {
                storage.enumerateAttributes(in: contentRange) { attrs, attrRange, _ in
                    let text = (storage.string as NSString).substring(with: attrRange)
                    let font = attrs[.font] as? NSFont ?? baseFont
                    let traits = fm.traits(of: font)
                    let isBold = traits.contains(.boldFontMask)
                    let isItalic = traits.contains(.italicFontMask)
                    let isUnderline = (attrs[.underlineStyle] as? Int ?? 0) > 0
                    let isStrikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) > 0

                    var chunk = text
                    if isBold && isItalic {
                        chunk = "***\(chunk)***"
                    } else if isBold {
                        chunk = "**\(chunk)**"
                    } else if isItalic {
                        chunk = "*\(chunk)*"
                    }
                    if isStrikethrough {
                        chunk = "~~\(chunk)~~"
                    }
                    if isUnderline {
                        chunk = "<u>\(chunk)</u>"
                    }
                    lineMarkdown += chunk
                }
            }

            result += markdownPrefix + lineMarkdown
            if hasNewline {
                result += "\n"
            }

            lineStart = lineRange.location + lineRange.length
        }

        return result
    }
}
