import AppKit
import SwiftUI
import WebKit

final class MarkdownEditorBundleProbe: NSObject {}

enum MarkdownEditorBridgeMessage: Equatable {
    case ready
    case contentChanged(String)

    static func decode(_ body: Any) -> MarkdownEditorBridgeMessage? {
        guard let payload = body as? [String: Any],
              let type = payload["type"] as? String
        else {
            return nil
        }

        switch type {
        case "ready":
            return .ready
        case "contentChanged":
            return .contentChanged(payload["markdown"] as? String ?? "")
        default:
            return nil
        }
    }
}

struct ToastMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Type your notes here..."
    var isEditable = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder, isEditable: isEditable)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        context.coordinator.attach(webView)
        Self.loadEditorPage(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.update(
            text: $text,
            placeholder: placeholder,
            isEditable: isEditable
        )
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
    }

    static func editorPageURL(in bundle: Bundle = Bundle(for: MarkdownEditorBundleProbe.self)) -> URL? {
        bundle.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownEditor")
    }

    private static func loadEditorPage(into webView: WKWebView) {
        guard let editorPageURL = editorPageURL() else {
            webView.loadHTMLString(
                """
                <html>
                <body style="font-family:-apple-system;padding:16px;">
                  Missing bundled markdown editor assets.
                </body>
                </html>
                """,
                baseURL: nil
            )
            return
        }

        webView.loadFileURL(editorPageURL, allowingReadAccessTo: editorPageURL.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let messageHandlerName = "casablancaEditor"

        var text: Binding<String>
        private var placeholder: String
        private var isEditable: Bool
        private var lastKnownMarkdown: String
        private var isReady = false
        private weak var webView: WKWebView?

        init(text: Binding<String>, placeholder: String, isEditable: Bool) {
            self.text = text
            self.placeholder = placeholder
            self.isEditable = isEditable
            self.lastKnownMarkdown = text.wrappedValue
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func update(text: Binding<String>, placeholder: String, isEditable: Bool) {
            self.text = text

            if self.placeholder != placeholder {
                self.placeholder = placeholder
                setPlaceholderIfReady()
            }

            if self.isEditable != isEditable {
                self.isEditable = isEditable
                setEditableIfReady()
            }

            if text.wrappedValue != lastKnownMarkdown {
                pushMarkdownIfReady(text.wrappedValue)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageHandlerName,
                  let bridgeMessage = MarkdownEditorBridgeMessage.decode(message.body)
            else {
                return
            }

            switch bridgeMessage {
            case .ready:
                isReady = true
                setPlaceholderIfReady()
                setEditableIfReady()
                pushMarkdownIfReady(text.wrappedValue)
            case let .contentChanged(markdown):
                guard markdown != lastKnownMarkdown else { return }
                lastKnownMarkdown = markdown
                if text.wrappedValue != markdown {
                    text.wrappedValue = markdown
                }
            }
        }

        private func pushMarkdownIfReady(_ markdown: String) {
            lastKnownMarkdown = markdown
            guard isReady else { return }
            evaluate("window.CasablancaEditor.setMarkdown(\(Self.javaScriptStringLiteral(markdown)));")
        }

        private func setPlaceholderIfReady() {
            guard isReady else { return }
            evaluate("window.CasablancaEditor.setPlaceholder(\(Self.javaScriptStringLiteral(placeholder)));")
        }

        private func setEditableIfReady() {
            guard isReady else { return }
            evaluate("window.CasablancaEditor.setEditable(\(isEditable ? "true" : "false"));")
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script)
        }

        static func javaScriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let literal = String(data: data, encoding: .utf8)
            else {
                return "\"\""
            }

            return literal
        }
    }
}

// MARK: - Editor appearance preferences

/// Reading text size for freeform markdown editors. Persisted as a raw string
/// via `@AppStorage(AppPreferenceKey.notesTextSize)`.
enum NotesTextSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 15
        case .large: return 18
        }
    }
}

/// Reading measure (max content width) for freeform markdown editors.
enum NotesReadingWidth: String, CaseIterable, Identifiable {
    case comfortable
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .full: return "Full"
        }
    }

    /// `nil` means "fill the available width".
    var maxWidth: CGFloat? {
        switch self {
        case .comfortable: return 680
        case .full: return nil
        }
    }
}

// MARK: - Formatting toolbar

/// A lightweight markdown formatting toolbar that wraps/inserts markdown syntax
/// into the bound text. Reusable across the prep editor and notes editor.
struct MarkdownFormattingToolbar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: CasaSpace.xxs) {
            formatButton("Bold", systemImage: "bold") { MarkdownEditing.wrap(&text, with: "**") }
                .keyboardShortcut("b", modifiers: .command)
            formatButton("Italic", systemImage: "italic") { MarkdownEditing.wrap(&text, with: "_") }
                .keyboardShortcut("i", modifiers: .command)

            separator

            formatButton("Heading", systemImage: "textformat.size") { MarkdownEditing.prefixLine(&text, with: "## ") }
            formatButton("Bullet List", systemImage: "list.bullet") { MarkdownEditing.prefixLine(&text, with: "- ") }
            formatButton("Checklist", systemImage: "checklist") { MarkdownEditing.prefixLine(&text, with: "- [ ] ") }

            separator

            formatButton("Code", systemImage: "chevron.left.forwardslash.chevron.right") { MarkdownEditing.wrap(&text, with: "`") }
            formatButton("Link", systemImage: "link") { MarkdownEditing.insertLink(&text) }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.borderSubtle)
            .frame(width: 1, height: 16)
            .padding(.horizontal, CasaSpace.xs)
    }

    private func formatButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textSecondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The "Aa" appearance popover: text size (3 steps) + reading width.
struct MarkdownAppearanceControl: View {
    @AppStorage(AppPreferenceKey.notesTextSize) private var textSizeRaw = NotesTextSize.medium.rawValue
    @AppStorage(AppPreferenceKey.notesReadingWidth) private var readingWidthRaw = NotesReadingWidth.comfortable.rawValue
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textSecondary)
        .help("Text size and reading width")
        .accessibilityLabel("Appearance")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                Text("Text size")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .textCase(.uppercase)

                Picker("Text size", selection: $textSizeRaw) {
                    ForEach(NotesTextSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Divider()

                Text("Reading width")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .textCase(.uppercase)

                Picker("Reading width", selection: $readingWidthRaw) {
                    ForEach(NotesReadingWidth.allCases) { width in
                        Text(width.label).tag(width.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(CasaSpace.md)
            .frame(width: 240)
        }
    }
}

// MARK: - Markdown editing helpers

/// Pure string transforms used by the formatting toolbar. Because the
/// `ToastMarkdownEditor` binding round-trips through the web view, these
/// operate on the whole text rather than a selection range. Bold/italic/code
/// append a wrapped empty token at the end (cursor lands inside on next sync);
/// heading/list prefixes are appended on a new line. Kept deliberately simple.
enum MarkdownEditing {
    static func wrap(_ text: inout String, with token: String) {
        text += "\(token)\(token)"
    }

    static func prefixLine(_ text: inout String, with prefix: String) {
        if text.isEmpty {
            text = prefix
        } else if text.hasSuffix("\n") {
            text += prefix
        } else {
            text += "\n\(prefix)"
        }
    }

    static func insertLink(_ text: inout String) {
        text += "[](url)"
    }
}

struct ToastMarkdownViewer: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator {
        Coordinator(markdown: markdown)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        context.coordinator.attach(webView)
        Self.loadViewerPage(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.update(markdown: markdown)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
    }

    static func viewerPageURL(in bundle: Bundle = Bundle(for: MarkdownEditorBundleProbe.self)) -> URL? {
        bundle.url(forResource: "viewer", withExtension: "html", subdirectory: "MarkdownEditor")
    }

    private static func loadViewerPage(into webView: WKWebView) {
        guard let viewerPageURL = viewerPageURL() else {
            webView.loadHTMLString(
                """
                <html>
                <body style="font-family:-apple-system;padding:16px;">
                  Missing bundled markdown viewer assets.
                </body>
                </html>
                """,
                baseURL: nil
            )
            return
        }

        webView.loadFileURL(viewerPageURL, allowingReadAccessTo: viewerPageURL.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let messageHandlerName = "casablancaViewer"

        private var markdown: String
        private var isReady = false
        private weak var webView: WKWebView?

        init(markdown: String) {
            self.markdown = markdown
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func update(markdown: String) {
            self.markdown = markdown
            pushMarkdownIfReady()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageHandlerName,
                  MarkdownEditorBridgeMessage.decode(message.body) == .ready
            else {
                return
            }

            isReady = true
            pushMarkdownIfReady()
        }

        private func pushMarkdownIfReady() {
            guard isReady else { return }
            let encoded = ToastMarkdownEditor.Coordinator.javaScriptStringLiteral(markdown)
            webView?.evaluateJavaScript("window.CasablancaViewer.setMarkdown(\(encoded));")
        }
    }
}
