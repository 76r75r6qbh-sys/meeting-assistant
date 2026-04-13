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
