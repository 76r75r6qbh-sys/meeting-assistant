import AppKit
import SwiftUI

// MARK: - Formatting Actions

enum MarkdownFormat {
    case bold
    case italic
    case underline
    case strikethrough
    case bulletList
    case numberedList
    case indent
    case outdent
}

// MARK: - Coordinator

final class MarkdownTextEditorCoordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var onFormat: ((MarkdownFormat) -> Void)?
    var isSyncing = false
    var baseFont: NSFont

    init(text: Binding<String>, font: NSFont) {
        self.text = text
        self.baseFont = font
    }

    func textDidChange(_ notification: Notification) {
        guard !isSyncing, let textView = notification.object as? NSTextView else { return }
        guard let storage = textView.textStorage else { return }
        isSyncing = true
        let markdown = MarkdownConverter.attributedStringToMarkdown(storage, baseFont: baseFont)
        if text.wrappedValue != markdown {
            text.wrappedValue = markdown
        }
        isSyncing = false
    }
}

// MARK: - NSViewRepresentable

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    @Binding var coordinator: MarkdownTextEditorCoordinator?

    func makeCoordinator() -> MarkdownTextEditorCoordinator {
        MarkdownTextEditorCoordinator(text: $text, font: font)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesRuler = false
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 4)

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: .greatestFiniteMagnitude
            )
        }

        // Load initial content
        let attributed = MarkdownConverter.markdownToAttributedString(text, baseFont: font)
        textView.textStorage?.setAttributedString(attributed)

        scrollView.documentView = textView

        DispatchQueue.main.async {
            context.coordinator.onFormat = { [weak textView] format in
                guard let textView else { return }
                Self.applyFormat(format, to: textView, baseFont: self.font)
            }
            self.coordinator = context.coordinator
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        guard !context.coordinator.isSyncing else { return }

        // Only update if the markdown content actually changed externally
        let currentMarkdown = MarkdownConverter.attributedStringToMarkdown(
            textView.textStorage ?? NSTextStorage(),
            baseFont: font
        )
        if currentMarkdown != text {
            context.coordinator.isSyncing = true
            let selectedRanges = textView.selectedRanges
            let attributed = MarkdownConverter.markdownToAttributedString(text, baseFont: font)
            textView.textStorage?.setAttributedString(attributed)
            // Restore selection if still valid
            let maxLen = textView.textStorage?.length ?? 0
            let validRanges = selectedRanges.compactMap { rangeValue -> NSValue? in
                let range = rangeValue.rangeValue
                if range.location + range.length <= maxLen {
                    return rangeValue
                }
                return NSValue(range: NSRange(location: min(range.location, maxLen), length: 0))
            }
            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
            context.coordinator.isSyncing = false
        }
        context.coordinator.text = $text
        context.coordinator.baseFont = font
    }

    // MARK: - Format Application (Rich Text)

    static func applyFormat(_ format: MarkdownFormat, to textView: NSTextView, baseFont: NSFont) {
        guard let storage = textView.textStorage else { return }
        let selectedRange = textView.selectedRange()

        switch format {
        case .bold:
            toggleTrait(.boldFontMask, in: storage, range: selectedRange, textView: textView, baseFont: baseFont)
        case .italic:
            toggleTrait(.italicFontMask, in: storage, range: selectedRange, textView: textView, baseFont: baseFont)
        case .underline:
            toggleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, in: storage, range: selectedRange, textView: textView)
        case .strikethrough:
            toggleAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, in: storage, range: selectedRange, textView: textView)
        case .bulletList:
            applyListPrefix("•\t", textView: textView, storage: storage, baseFont: baseFont)
        case .numberedList:
            applyNumberedListPrefix(textView: textView, storage: storage, baseFont: baseFont)
        case .indent:
            adjustIndent(by: 24, textView: textView, storage: storage, baseFont: baseFont)
        case .outdent:
            adjustIndent(by: -24, textView: textView, storage: storage, baseFont: baseFont)
        }
    }

    private static func toggleTrait(
        _ trait: NSFontTraitMask,
        in storage: NSTextStorage,
        range: NSRange,
        textView: NSTextView,
        baseFont: NSFont
    ) {
        guard range.length > 0 else {
            // Toggle typing attributes for future input
            var attrs = textView.typingAttributes
            let currentFont = attrs[.font] as? NSFont ?? baseFont
            let fm = NSFontManager.shared
            let newFont: NSFont
            if fm.traits(of: currentFont).contains(trait) {
                newFont = fm.convert(currentFont, toNotHaveTrait: trait)
            } else {
                newFont = fm.convert(currentFont, toHaveTrait: trait)
            }
            attrs[.font] = newFont
            textView.typingAttributes = attrs
            return
        }

        storage.beginEditing()
        let fm = NSFontManager.shared
        // Check if entire range already has the trait
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = value as? NSFont ?? baseFont
            if !fm.traits(of: font).contains(trait) {
                allHaveTrait = false
            }
        }

        storage.enumerateAttribute(.font, in: range) { value, attrRange, _ in
            let font = value as? NSFont ?? baseFont
            let newFont: NSFont
            if allHaveTrait {
                newFont = fm.convert(font, toNotHaveTrait: trait)
            } else {
                newFont = fm.convert(font, toHaveTrait: trait)
            }
            storage.addAttribute(.font, value: newFont, range: attrRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private static func toggleAttribute(
        _ key: NSAttributedString.Key,
        value: Int,
        in storage: NSTextStorage,
        range: NSRange,
        textView: NSTextView
    ) {
        guard range.length > 0 else {
            var attrs = textView.typingAttributes
            let current = attrs[key] as? Int ?? 0
            attrs[key] = current > 0 ? 0 : value
            textView.typingAttributes = attrs
            return
        }

        storage.beginEditing()
        // Check if entire range already has the attribute
        var allHaveAttr = true
        storage.enumerateAttribute(key, in: range) { val, _, _ in
            if (val as? Int ?? 0) == 0 {
                allHaveAttr = false
            }
        }

        if allHaveAttr {
            storage.removeAttribute(key, range: range)
        } else {
            storage.addAttribute(key, value: value, range: range)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private static func applyListPrefix(_ prefix: String, textView: NSTextView, storage: NSTextStorage, baseFont: NSFont) {
        let selectedRange = textView.selectedRange()
        let string = storage.string as NSString
        let lineRange = string.lineRange(for: selectedRange)
        let linesText = string.substring(with: lineRange)
        let lines = linesText.components(separatedBy: "\n")

        // Check if all lines already have bullet
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allHaveBullet = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix("•\t") || $0.hasPrefix("• ") }

        storage.beginEditing()
        var offset = lineRange.location
        for line in lines {
            let lineLen = (line as NSString).length
            let currentLineRange = NSRange(location: offset, length: lineLen)

            if allHaveBullet {
                // Remove bullet
                if line.hasPrefix("•\t") {
                    storage.replaceCharacters(in: NSRange(location: offset, length: 2), with: "")
                    offset += lineLen - 2 + 1
                } else if line.hasPrefix("• ") {
                    storage.replaceCharacters(in: NSRange(location: offset, length: 2), with: "")
                    offset += lineLen - 2 + 1
                } else {
                    offset += lineLen + 1
                }
            } else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.hasPrefix("•") {
                    let insertStr = NSAttributedString(string: prefix, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
                    storage.insert(insertStr, at: offset)
                    offset += lineLen + prefix.count + 1
                } else {
                    offset += lineLen + 1
                }
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private static func applyNumberedListPrefix(textView: NSTextView, storage: NSTextStorage, baseFont: NSFont) {
        let selectedRange = textView.selectedRange()
        let string = storage.string as NSString
        let lineRange = string.lineRange(for: selectedRange)
        let linesText = string.substring(with: lineRange)
        let lines = linesText.components(separatedBy: "\n")

        let numberPattern = /^\d+\.\s/
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allNumbered = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.contains(numberPattern) }

        storage.beginEditing()
        // Replace the whole line range at once to avoid offset tracking issues
        var newLines: [String] = []
        var counter = 1
        for line in lines {
            if allNumbered {
                newLines.append(line.replacing(numberPattern, with: ""))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                newLines.append(line)
            } else {
                newLines.append("\(counter).\t\(line)")
                counter += 1
            }
        }
        let newText = newLines.joined(separator: "\n")
        let attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.labelColor]
        // Preserve existing attributes for non-prefix parts by replacing the range
        storage.replaceCharacters(in: lineRange, with: NSAttributedString(string: newText, attributes: attrs))
        storage.endEditing()
        textView.didChangeText()
    }

    private static func adjustIndent(by points: CGFloat, textView: NSTextView, storage: NSTextStorage, baseFont: NSFont) {
        let selectedRange = textView.selectedRange()
        let string = storage.string as NSString
        let lineRange = string.lineRange(for: selectedRange)

        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: lineRange) { value, attrRange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.headIndent = max(0, style.headIndent + points)
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + points)
            storage.addAttribute(.paragraphStyle, value: style, range: attrRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }
}

// MARK: - Markdown ↔ AttributedString Converter

enum MarkdownConverter {

    // MARK: Markdown → NSAttributedString

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

            // Handle bullet lists
            if processedLine.hasPrefix("- ") {
                processedLine = String(processedLine.dropFirst(2))
                paragraphPrefix = "•\t"
            } else if processedLine.hasPrefix("* ") && !processedLine.hasPrefix("**") {
                processedLine = String(processedLine.dropFirst(2))
                paragraphPrefix = "•\t"
            }

            // Handle numbered lists
            if let match = processedLine.prefixMatch(of: /^(\d+)\.\s/) {
                processedLine = String(processedLine[match.range.upperBound...])
                paragraphPrefix = "\(match.1).\t"
            }

            // Parse inline formatting
            let attributed = parseInlineFormatting(processedLine, baseFont: lineBaseFont, fontManager: fm)

            // Prepend list prefix
            if !paragraphPrefix.isEmpty {
                let prefixAttrs: [NSAttributedString.Key: Any] = [
                    .font: lineBaseFont,
                    .foregroundColor: NSColor.labelColor,
                ]
                let prefixStr = NSAttributedString(string: paragraphPrefix, attributes: prefixAttrs)
                let combined = NSMutableAttributedString()
                combined.append(prefixStr)
                combined.append(attributed)
                result.append(combined)
            } else {
                result.append(attributed)
            }

            // Add newline between lines (not after last)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: lineBaseFont]))
            }
        }

        return result
    }

    private static func parseInlineFormatting(_ text: String, baseFont: NSFont, fontManager fm: NSFontManager) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var index = text.startIndex
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        while index < text.endIndex {
            // Bold + Italic: ***text***
            if text[index...].hasPrefix("***"), let endRange = text[text.index(after: text.index(after: text.index(after: index)))...].range(of: "***") {
                let contentStart = text.index(index, offsetBy: 3)
                let content = String(text[contentStart..<endRange.lowerBound])
                let boldItalicFont = fm.convert(fm.convert(baseFont, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask)
                var attrs = baseAttrs
                attrs[.font] = boldItalicFont
                result.append(NSAttributedString(string: content, attributes: attrs))
                index = text.index(endRange.upperBound, offsetBy: 0)
                continue
            }

            // Bold: **text**
            if text[index...].hasPrefix("**"), let endRange = text[text.index(after: text.index(after: index))...].range(of: "**") {
                let contentStart = text.index(index, offsetBy: 2)
                let content = String(text[contentStart..<endRange.lowerBound])
                let boldFont = fm.convert(baseFont, toHaveTrait: .boldFontMask)
                var attrs = baseAttrs
                attrs[.font] = boldFont
                result.append(NSAttributedString(string: content, attributes: attrs))
                index = endRange.upperBound
                continue
            }

            // Italic: *text* (but not **)
            if text[index...].hasPrefix("*") && !text[index...].hasPrefix("**") {
                let searchStart = text.index(after: index)
                if searchStart < text.endIndex, let endIdx = text[searchStart...].firstIndex(of: "*") {
                    let content = String(text[searchStart..<endIdx])
                    if !content.isEmpty && !content.hasPrefix(" ") && !content.hasSuffix(" ") {
                        let italicFont = fm.convert(baseFont, toHaveTrait: .italicFontMask)
                        var attrs = baseAttrs
                        attrs[.font] = italicFont
                        result.append(NSAttributedString(string: content, attributes: attrs))
                        index = text.index(after: endIdx)
                        continue
                    }
                }
            }

            // Strikethrough: ~~text~~
            if text[index...].hasPrefix("~~") {
                let searchStart = text.index(index, offsetBy: 2)
                if searchStart < text.endIndex, let endRange = text[searchStart...].range(of: "~~") {
                    let content = String(text[searchStart..<endRange.lowerBound])
                    var attrs = baseAttrs
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    result.append(NSAttributedString(string: content, attributes: attrs))
                    index = endRange.upperBound
                    continue
                }
            }

            // Underline: <u>text</u>
            if text[index...].hasPrefix("<u>") {
                let searchStart = text.index(index, offsetBy: 3)
                if searchStart < text.endIndex, let endRange = text[searchStart...].range(of: "</u>") {
                    let content = String(text[searchStart..<endRange.lowerBound])
                    var attrs = baseAttrs
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    result.append(NSAttributedString(string: content, attributes: attrs))
                    index = endRange.upperBound
                    continue
                }
            }

            // Plain character
            result.append(NSAttributedString(string: String(text[index]), attributes: baseAttrs))
            index = text.index(after: index)
        }

        return result
    }

    // MARK: NSAttributedString → Markdown

    static func attributedStringToMarkdown(_ storage: NSAttributedString, baseFont: NSFont) -> String {
        let string = storage.string
        guard !string.isEmpty else { return "" }

        var result = ""
        let fm = NSFontManager.shared
        let fullRange = NSRange(location: 0, length: storage.length)

        // Process line by line
        let nsString = string as NSString
        var lineStart = 0
        while lineStart < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: lineStart, length: 0))
            var lineText = nsString.substring(with: lineRange)

            // Remove trailing newline for processing
            let hasNewline = lineText.hasSuffix("\n")
            if hasNewline {
                lineText = String(lineText.dropLast())
            }

            // Check for bullet prefix
            var markdownPrefix = ""
            var contentOffset = 0
            if lineText.hasPrefix("•\t") || lineText.hasPrefix("• ") {
                markdownPrefix = "- "
                contentOffset = 2
            } else if let match = lineText.prefixMatch(of: /^(\d+)\.\t/) {
                markdownPrefix = "\(match.1). "
                contentOffset = match.0.count
            }

            // Build inline markdown for the content portion
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

// MARK: - Formatting Toolbar

struct MarkdownFormattingToolbar: View {
    var coordinator: MarkdownTextEditorCoordinator?

    var body: some View {
        HStack(spacing: CasaSpace.xxs) {
            formatButton(icon: "bold", format: .bold, tooltip: "Bold (⌘B)")
            formatButton(icon: "italic", format: .italic, tooltip: "Italic (⌘I)")
            formatButton(icon: "underline", format: .underline, tooltip: "Underline (⌘U)")
            formatButton(icon: "strikethrough", format: .strikethrough, tooltip: "Strikethrough")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, CasaSpace.xxs)

            formatButton(icon: "list.bullet", format: .bulletList, tooltip: "Bullet List")
            formatButton(icon: "list.number", format: .numberedList, tooltip: "Numbered List")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, CasaSpace.xxs)

            formatButton(icon: "increase.indent", format: .indent, tooltip: "Indent")
            formatButton(icon: "decrease.indent", format: .outdent, tooltip: "Outdent")
        }
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xs)
    }

    private func formatButton(icon: String, format: MarkdownFormat, tooltip: String) -> some View {
        Button {
            coordinator?.onFormat?(format)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(Color.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
        .help(tooltip)
    }
}
