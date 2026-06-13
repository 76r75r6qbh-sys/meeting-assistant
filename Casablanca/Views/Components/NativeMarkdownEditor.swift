import AppKit
import SwiftUI

// MARK: - Pure syntax-styling model

/// A display-attribute range computed for a single line of markdown. These are
/// *display* attributes only — the underlying characters (including the markdown
/// syntax markers) are never mutated. This is a "highlight the markdown" model,
/// NOT a hide-syntax WYSIWYG.
struct MarkdownStyleSpan: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case bold
        case italic
        case code
        case listMarker
    }

    /// Range relative to the start of the line it was computed for.
    let range: NSRange
    let kind: Kind
}

/// Pure functions that compute syntax-highlight ranges for a markdown line.
/// Kept free of AppKit view state so they can be unit-tested directly.
enum MarkdownSyntaxStyling {

    /// Compute style spans for a single line (no trailing newline). Ranges are
    /// relative to the start of `line`.
    static func spans(for line: String) -> [MarkdownStyleSpan] {
        var spans: [MarkdownStyleSpan] = []
        let ns = line as NSString

        // Heading: leading #..###### followed by a space. The whole line is the
        // heading display range so the syntax markers render at the larger size.
        if let headingLevel = headingLevel(for: line) {
            spans.append(MarkdownStyleSpan(range: NSRange(location: 0, length: ns.length), kind: .heading(level: headingLevel)))
        } else if let markerLength = listMarkerLength(for: line) {
            // List marker (-, *, 1.) including the trailing space.
            spans.append(MarkdownStyleSpan(range: NSRange(location: 0, length: markerLength), kind: .listMarker))
        }

        // Inline spans: bold (**..**), italic (_.._), code (`..`).
        spans.append(contentsOf: inlineSpans(for: line))
        return spans
    }

    /// Heading level 1...6 if the line begins with the right number of `#`
    /// followed by a space; otherwise nil.
    static func headingLevel(for line: String) -> Int? {
        var hashes = 0
        for char in line {
            if char == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let afterHashes = line.index(line.startIndex, offsetBy: hashes)
        guard afterHashes < line.endIndex, line[afterHashes] == " " else { return nil }
        return hashes
    }

    /// Length (in UTF-16 units) of a leading list marker including its trailing
    /// space (`- `, `* `, `1. `), or nil if the line isn't a list item.
    static func listMarkerLength(for line: String) -> Int? {
        // Unordered: "- " or "* " (but not "**" which is bold)
        if line.hasPrefix("- ") { return 2 }
        if line.hasPrefix("* ") { return 2 }

        // Ordered: digits followed by ". "
        if let match = line.prefixMatch(of: /^(\d+)\.\s/) {
            return (line as NSString).length(of: match.0)
        }
        return nil
    }

    /// Inline emphasis spans for a line. Ranges cover the full delimited token
    /// (including the markers) so the markers are tinted alongside the content.
    static func inlineSpans(for line: String) -> [MarkdownStyleSpan] {
        var spans: [MarkdownStyleSpan] = []
        let ns = line as NSString
        spans.append(contentsOf: pairedSpans(in: ns, delimiter: "**", kind: .bold))
        spans.append(contentsOf: pairedSpans(in: ns, delimiter: "`", kind: .code))
        spans.append(contentsOf: pairedSpans(in: ns, delimiter: "_", kind: .italic, requireWordBoundary: true))
        return spans
    }

    /// Find non-overlapping paired-delimiter spans. `requireWordBoundary` is used
    /// for `_italic_` to avoid matching snake_case in the middle of words.
    private static func pairedSpans(
        in ns: NSString,
        delimiter: String,
        kind: MarkdownStyleSpan.Kind,
        requireWordBoundary: Bool = false
    ) -> [MarkdownStyleSpan] {
        var spans: [MarkdownStyleSpan] = []
        let delimNS = delimiter as NSString
        let delimLen = delimNS.length
        var searchStart = 0

        while searchStart < ns.length {
            let openRange = ns.range(
                of: delimiter,
                options: [],
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            guard openRange.location != NSNotFound else { break }

            let contentStart = openRange.location + delimLen
            guard contentStart < ns.length else { break }

            let closeSearch = NSRange(location: contentStart, length: ns.length - contentStart)
            let closeRange = ns.range(of: delimiter, options: [], range: closeSearch)
            guard closeRange.location != NSNotFound else { break }

            let contentLen = closeRange.location - contentStart
            // Reject empty content (e.g. "****").
            if contentLen == 0 {
                searchStart = closeRange.location + delimLen
                continue
            }

            let fullRange = NSRange(location: openRange.location, length: closeRange.location + delimLen - openRange.location)

            if requireWordBoundary, !isWordBoundaryDelimited(ns: ns, range: fullRange) {
                searchStart = openRange.location + delimLen
                continue
            }

            spans.append(MarkdownStyleSpan(range: fullRange, kind: kind))
            searchStart = closeRange.location + delimLen
        }

        return spans
    }

    /// True if the character before the span is not a word character and the
    /// content does not start/end with whitespace. Guards `_italic_` from
    /// matching `foo_bar_baz`.
    private static func isWordBoundaryDelimited(ns: NSString, range: NSRange) -> Bool {
        let wordChars = CharacterSet.alphanumerics
        if range.location > 0 {
            let before = ns.substring(with: NSRange(location: range.location - 1, length: 1))
            if before.rangeOfCharacter(from: wordChars) != nil { return false }
        }
        let afterIndex = range.location + range.length
        if afterIndex < ns.length {
            let after = ns.substring(with: NSRange(location: afterIndex, length: 1))
            if after.rangeOfCharacter(from: wordChars) != nil { return false }
        }
        return true
    }
}

private extension NSString {
    /// UTF-16 length of a Swift substring match.
    func length(of substring: Substring) -> Int {
        (String(substring) as NSString).length
    }
}

// MARK: - Pure selection-aware editing model

/// Result of a selection-aware markdown transform: the new full text and the new
/// selection range to apply. Pure and unit-testable.
struct MarkdownSelectionEdit: Equatable {
    let text: String
    let selectedRange: NSRange
}

enum MarkdownSelectionSyntax: Equatable {
    case bold
    case italic
    case code
    case heading
    case list
    case checklist
    case link

    var inlineToken: String? {
        switch self {
        case .bold: return "**"
        case .italic: return "_"
        case .code: return "`"
        case .heading, .list, .checklist, .link: return nil
        }
    }

    var linePrefix: String? {
        switch self {
        case .heading: return "## "
        case .list: return "- "
        case .checklist: return "- [ ] "
        case .bold, .italic, .code, .link: return nil
        }
    }

    /// A snippet inserted at the caret (no selection-wrapping). Used for links,
    /// where the caret lands inside the `[]` so the user can type link text.
    var caretInsertion: (text: String, caretOffset: Int)? {
        switch self {
        case .link: return ("[](url)", 1) // caret between the brackets
        case .bold, .italic, .code, .heading, .list, .checklist: return nil
        }
    }
}

enum MarkdownSelectionEditing {

    /// Apply a markdown transform around the current selection (or caret). For
    /// inline tokens this wraps the selection (or inserts an empty token at the
    /// caret with the caret placed between the markers). For line prefixes it
    /// toggles the prefix on each line touched by the selection.
    static func apply(
        _ syntax: MarkdownSelectionSyntax,
        to text: String,
        selectedRange: NSRange
    ) -> MarkdownSelectionEdit {
        if let token = syntax.inlineToken {
            return wrap(text: text, selectedRange: selectedRange, token: token)
        } else if let prefix = syntax.linePrefix {
            return prefixLines(text: text, selectedRange: selectedRange, prefix: prefix)
        } else if let insertion = syntax.caretInsertion {
            return insertAtCaret(text: text, selectedRange: selectedRange, insertion: insertion)
        }
        return MarkdownSelectionEdit(text: text, selectedRange: selectedRange)
    }

    private static func insertAtCaret(
        text: String,
        selectedRange: NSRange,
        insertion: (text: String, caretOffset: Int)
    ) -> MarkdownSelectionEdit {
        let ns = text as NSString
        let safeRange = clamp(selectedRange, length: ns.length)
        let newText = ns.replacingCharacters(in: safeRange, with: insertion.text)
        let caret = NSRange(location: safeRange.location + insertion.caretOffset, length: 0)
        return MarkdownSelectionEdit(text: newText, selectedRange: caret)
    }

    private static func wrap(text: String, selectedRange: NSRange, token: String) -> MarkdownSelectionEdit {
        let ns = text as NSString
        let safeRange = clamp(selectedRange, length: ns.length)
        let tokenNS = token as NSString
        let tokenLen = tokenNS.length

        if safeRange.length == 0 {
            // Insert paired markers at caret; place caret between them.
            let newText = ns.replacingCharacters(in: safeRange, with: token + token)
            let caret = NSRange(location: safeRange.location + tokenLen, length: 0)
            return MarkdownSelectionEdit(text: newText, selectedRange: caret)
        }

        let selected = ns.substring(with: safeRange)
        let wrapped = token + selected + token
        let newText = ns.replacingCharacters(in: safeRange, with: wrapped)
        // Keep the original content selected (between the markers).
        let newSelection = NSRange(location: safeRange.location + tokenLen, length: safeRange.length)
        return MarkdownSelectionEdit(text: newText, selectedRange: newSelection)
    }

    private static func prefixLines(text: String, selectedRange: NSRange, prefix: String) -> MarkdownSelectionEdit {
        let ns = text as NSString
        let safeRange = clamp(selectedRange, length: ns.length)
        // Expand to whole lines touched by the selection.
        let lineRange = ns.lineRange(for: safeRange)
        let block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        let body = hadTrailingNewline ? String(block.dropLast()) : block
        let lines = body.components(separatedBy: "\n")

        let prefixed = lines.map { line -> String in
            line.hasPrefix(prefix) ? line : prefix + line
        }
        var rebuilt = prefixed.joined(separator: "\n")
        if hadTrailingNewline { rebuilt += "\n" }

        let newText = ns.replacingCharacters(in: lineRange, with: rebuilt)
        // Select the whole rebuilt block.
        let newSelection = NSRange(location: lineRange.location, length: (rebuilt as NSString).length)
        return MarkdownSelectionEdit(text: newText, selectedRange: newSelection)
    }

    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let maxLen = length - location
        let len = min(max(range.length, 0), maxLen)
        return NSRange(location: location, length: len)
    }
}

// MARK: - NSTextStorageDelegate that applies live syntax styling

/// Applies display-only markdown highlighting to edited paragraphs. The base
/// font/size is supplied by the editor; heading/bold/italic/code/list spans get
/// derived fonts/colors.
final class MarkdownStylingTextStorageDelegate: NSObject, NSTextStorageDelegate {
    var baseFont: NSFont

    init(baseFont: NSFont) {
        self.baseFont = baseFont
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let full = textStorage.string as NSString
        // Restyle all paragraphs that intersect the edit (lineRange handles the
        // multi-paragraph case after a paste).
        let paragraphRange = full.paragraphRange(for: editedRange)
        applyStyles(to: textStorage, in: paragraphRange)
    }

    /// Style every line within `range`. Safe to call directly (initial load).
    func applyStyles(to textStorage: NSTextStorage, in range: NSRange) {
        let full = textStorage.string as NSString
        guard full.length > 0 else { return }
        let clamped = NSRange(location: range.location, length: min(range.length, full.length - range.location))

        // Reset to base attributes across the styled range first.
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        textStorage.setAttributes(baseAttrs, range: clamped)

        full.enumerateSubstrings(in: clamped, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = full.substring(with: lineRange)
            for span in MarkdownSyntaxStyling.spans(for: line) {
                let absolute = NSRange(location: lineRange.location + span.range.location, length: span.range.length)
                guard absolute.location + absolute.length <= full.length else { continue }
                self.attributes(for: span.kind).forEach { key, value in
                    textStorage.addAttribute(key, value: value, range: absolute)
                }
            }
        }
    }

    private func attributes(for kind: MarkdownStyleSpan.Kind) -> [NSAttributedString.Key: Any] {
        let fm = NSFontManager.shared
        switch kind {
        case let .heading(level):
            let bump: CGFloat
            switch level {
            case 1: bump = 8
            case 2: bump = 4
            case 3: bump = 2
            default: bump = 1
            }
            return [.font: NSFont.systemFont(ofSize: baseFont.pointSize + bump, weight: .bold)]
        case .bold:
            return [.font: fm.convert(baseFont, toHaveTrait: .boldFontMask)]
        case .italic:
            return [.font: fm.convert(baseFont, toHaveTrait: .italicFontMask)]
        case .code:
            let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            return [
                .font: mono,
                .foregroundColor: NSColor.systemPink,
            ]
        case .listMarker:
            return [.foregroundColor: NSColor.controlAccentColor]
        }
    }
}

// MARK: - Formatter handle exposed to toolbars

/// A lightweight, value-type handle a parent (e.g. a formatting toolbar) can use
/// to drive selection-aware formatting on the active native editor. It holds the
/// coordinator *weakly*, so a stale handle left in parent `@State` after the
/// editor goes away simply no-ops rather than leaking the editor.
struct MarkdownEditorFormatter: Equatable {
    fileprivate weak var coordinator: NativeMarkdownEditor.Coordinator?

    fileprivate init(coordinator: NativeMarkdownEditor.Coordinator) {
        self.coordinator = coordinator
    }

    /// Apply a markdown transform around the editor's current selection. No-ops
    /// if the underlying editor is gone.
    func apply(_ syntax: MarkdownSelectionSyntax) {
        coordinator?.applyMarkdown(syntax)
    }

    static func == (lhs: MarkdownEditorFormatter, rhs: MarkdownEditorFormatter) -> Bool {
        lhs.coordinator === rhs.coordinator
    }
}

// MARK: - NSViewRepresentable editor

/// Native NSTextView-based markdown editor. Contract is identical to
/// `ToastMarkdownEditor`: the binding holds raw markdown (the source of truth),
/// and syntax is *highlighted* in place rather than hidden. Native NSUndoManager,
/// ⌘F find, and dictation all work for free.
struct NativeMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Type your notes here..."
    var isEditable = true

    /// Optional handle a parent can bind to in order to drive selection-aware
    /// formatting (e.g. a toolbar). The Representable assigns the live coordinator
    /// when the view is created and clears it when the view is dismantled, so the
    /// parent never holds a stale reference after the editor goes away.
    var formatter: Binding<MarkdownEditorFormatter?>?

    @AppStorage(AppPreferenceKey.notesTextSize) private var textSizeRaw = NotesTextSize.medium.rawValue
    @AppStorage(AppPreferenceKey.notesReadingWidth) private var readingWidthRaw = NotesReadingWidth.comfortable.rawValue

    private var textSize: NotesTextSize { NotesTextSize(rawValue: textSizeRaw) ?? .medium }
    private var readingWidth: NotesReadingWidth { NotesReadingWidth(rawValue: readingWidthRaw) ?? .comfortable }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // Drop the parent's handle so it can't invoke a coordinator whose text
        // view is gone. The formatter holds the coordinator weakly anyway, but
        // clearing keeps the parent's `@State` tidy.
        coordinator.clearFormatterBinding()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        let baseFont = NSFont.systemFont(ofSize: textSize.pointSize)
        let delegate = MarkdownStylingTextStorageDelegate(baseFont: baseFont)
        context.coordinator.stylingDelegate = delegate
        context.coordinator.textView = textView

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = delegate
        textView.isRichText = false          // plain text source of truth
        textView.allowsUndo = true           // native NSUndoManager
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true          // ⌘F find
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.font = baseFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        // Seed initial content + styling.
        textView.string = text
        context.coordinator.lastKnownText = text
        if let storage = textView.textStorage {
            delegate.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length))
        }

        applyLayout(to: textView)
        context.coordinator.updatePlaceholder(placeholder, isEmpty: text.isEmpty)
        textView.isEditable = isEditable
        textView.isSelectable = true

        // Publish a formatter handle to the parent (e.g. the formatting toolbar).
        context.coordinator.publishFormatter(to: formatter)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Font / layout changes from preferences.
        let baseFont = NSFont.systemFont(ofSize: textSize.pointSize)
        if context.coordinator.stylingDelegate?.baseFont.pointSize != baseFont.pointSize {
            context.coordinator.stylingDelegate?.baseFont = baseFont
            textView.font = baseFont
            if let storage = textView.textStorage {
                context.coordinator.stylingDelegate?.applyStyles(
                    to: storage,
                    in: NSRange(location: 0, length: storage.length)
                )
            }
        }
        applyLayout(to: textView)

        textView.isEditable = isEditable

        // External text change: only overwrite when it actually differs from
        // what the view holds, to avoid clobbering the caret while typing.
        if text != context.coordinator.lastKnownText, text != textView.string {
            let selected = textView.selectedRange()
            textView.string = text
            context.coordinator.lastKnownText = text
            if let storage = textView.textStorage {
                context.coordinator.stylingDelegate?.applyStyles(
                    to: storage,
                    in: NSRange(location: 0, length: storage.length)
                )
            }
            let clampedLoc = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))
        } else {
            context.coordinator.lastKnownText = text
        }

        context.coordinator.updatePlaceholder(placeholder, isEmpty: textView.string.isEmpty)

        // Keep the parent's handle pointing at this live coordinator (idempotent).
        context.coordinator.publishFormatter(to: formatter)
    }

    private func applyLayout(to textView: NSTextView) {
        // Reading width via horizontal inset so the measure narrows symmetrically
        // while the text view still fills its frame (no collapse).
        let verticalInset: CGFloat = 8
        if let maxWidth = readingWidth.maxWidth {
            let available = textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width
            let inset = max(8, (available - maxWidth) / 2)
            textView.textContainerInset = NSSize(width: inset, height: verticalInset)
        } else {
            textView.textContainerInset = NSSize(width: 8, height: verticalInset)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var lastKnownText: String = ""
        weak var textView: NSTextView?
        var stylingDelegate: MarkdownStylingTextStorageDelegate?
        private var placeholderLayer: PlaceholderState?
        private var formatterBinding: Binding<MarkdownEditorFormatter?>?

        private struct PlaceholderState {
            var text: String
        }

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newValue = textView.string
            lastKnownText = newValue
            if text.wrappedValue != newValue {
                text.wrappedValue = newValue
            }
            updatePlaceholder(placeholderLayer?.text ?? "", isEmpty: newValue.isEmpty)
        }

        func updatePlaceholder(_ placeholder: String, isEmpty: Bool) {
            placeholderLayer = PlaceholderState(text: placeholder)
            guard let textView = textView else { return }
            if isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.placeholderTextColor,
                ]
                textView.setValue(
                    NSAttributedString(string: placeholder, attributes: attrs),
                    forKey: "placeholderAttributedString"
                )
            } else {
                textView.setValue(NSAttributedString(string: ""), forKey: "placeholderAttributedString")
            }
        }

        /// Publish a weak formatter handle into the parent's binding so a toolbar
        /// can drive `applyMarkdown`. Idempotent — safe to call from update too.
        func publishFormatter(to binding: Binding<MarkdownEditorFormatter?>?) {
            formatterBinding = binding
            guard let binding else { return }
            let handle = MarkdownEditorFormatter(coordinator: self)
            // Avoid a redundant write (and a SwiftUI update cycle) if already set.
            if binding.wrappedValue?.coordinator !== self {
                binding.wrappedValue = handle
            }
        }

        /// Clear the parent's handle (called on dismantle).
        func clearFormatterBinding() {
            formatterBinding?.wrappedValue = nil
            formatterBinding = nil
        }

        /// Selection-aware formatting entry point used by toolbars.
        func applyMarkdown(_ syntax: MarkdownSelectionSyntax) {
            guard let textView = textView else { return }
            let result = MarkdownSelectionEditing.apply(
                syntax,
                to: textView.string,
                selectedRange: textView.selectedRange()
            )
            // Route through NSTextView so undo + delegate notifications fire.
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: fullRange, replacementString: result.text) {
                textView.textStorage?.replaceCharacters(in: fullRange, with: result.text)
                textView.didChangeText()
            }
            textView.setSelectedRange(result.selectedRange)
        }
    }
}

// MARK: - Native read-only viewer

/// Read-only markdown rendering without WKWebView, using the existing
/// `MarkdownConverter.markdownToAttributedString`. Replaces `ToastMarkdownViewer`
/// when the native editor flag is on.
struct NativeMarkdownViewer: View {
    let markdown: String

    @AppStorage(AppPreferenceKey.notesTextSize) private var textSizeRaw = NotesTextSize.medium.rawValue

    private var textSize: NotesTextSize { NotesTextSize(rawValue: textSizeRaw) ?? .medium }

    private var attributed: AttributedString {
        let ns = MarkdownConverter.markdownToAttributedString(
            markdown,
            baseFont: .systemFont(ofSize: textSize.pointSize)
        )
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(ns.string)
    }

    var body: some View {
        ScrollView {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
