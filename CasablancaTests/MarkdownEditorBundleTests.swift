import XCTest
@testable import Casablanca

final class MarkdownEditorBundleTests: XCTestCase {
    func testBridgeMessageDecoding() {
        XCTAssertEqual(
            MarkdownEditorBridgeMessage.decode(["type": "ready"]),
            .ready
        )
        XCTAssertEqual(
            MarkdownEditorBridgeMessage.decode([
                "type": "contentChanged",
                "markdown": "# Follow-ups",
            ]),
            .contentChanged("# Follow-ups")
        )
        XCTAssertNil(MarkdownEditorBridgeMessage.decode(["type": "unsupported"]))
    }

    func testBundledEditorAssetsAreAvailable() {
        let bundle = Bundle(for: MarkdownEditorBundleProbe.self)

        XCTAssertNotNil(ToastMarkdownEditor.editorPageURL(in: bundle))
        XCTAssertNotNil(
            bundle.url(
                forResource: "toastui-editor-all.min",
                withExtension: "js",
                subdirectory: "MarkdownEditor"
            )
        )
        XCTAssertNotNil(
            bundle.url(
                forResource: "toastui-editor.min",
                withExtension: "css",
                subdirectory: "MarkdownEditor"
            )
        )
    }

    func testBundledViewerAssetsAreAvailable() {
        let bundle = Bundle(for: MarkdownEditorBundleProbe.self)

        XCTAssertNotNil(ToastMarkdownViewer.viewerPageURL(in: bundle))
        XCTAssertNotNil(
            bundle.url(
                forResource: "viewer-bridge",
                withExtension: "js",
                subdirectory: "MarkdownEditor"
            )
        )
    }

    func testBundledEditorSupportsDarkMode() throws {
        let bundle = Bundle(for: MarkdownEditorBundleProbe.self)
        let editorURL = try XCTUnwrap(ToastMarkdownEditor.editorPageURL(in: bundle))
        let html = try String(contentsOf: editorURL, encoding: .utf8)

        XCTAssertTrue(html.contains("color-scheme: light dark"))
        XCTAssertTrue(html.contains("@media (prefers-color-scheme: dark)"))
    }

    func testBundledViewerSupportsDarkMode() throws {
        let bundle = Bundle(for: MarkdownEditorBundleProbe.self)
        let viewerURL = try XCTUnwrap(ToastMarkdownViewer.viewerPageURL(in: bundle))
        let html = try String(contentsOf: viewerURL, encoding: .utf8)

        XCTAssertTrue(html.contains("color-scheme: light dark"))
        XCTAssertTrue(html.contains("@media (prefers-color-scheme: dark)"))
    }
}
