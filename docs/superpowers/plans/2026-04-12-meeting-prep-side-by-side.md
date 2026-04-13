# Meeting Prep Side-by-Side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a matching Obsidian `- Prep.md` note in a collapsible read-only pane beside live meeting notes, while keeping the existing full-width editor when no prep file exists.

**Architecture:** Add a small `MeetingPrepService` that resolves and reads the Obsidian prep file without changing SwiftData models. Add a dedicated read-only `ToastMarkdownViewer` backed by the bundled Toast UI assets so Markdown renders correctly, then extend `NotesEditorView` with local prep-loading state and a prep-aware split layout that always starts expanded.

**Tech Stack:** SwiftUI, AppKit, WebKit, SwiftData, XCTest, Toast UI Editor bundled assets

---

## File Map

- Create: `Casablanca/Services/MeetingPrepService.swift`
  - Resolve `meeting notes/<meeting.obsidianFileName> - Prep.md`
  - Read UTF-8 Markdown from disk and return `nil` on missing/unreadable prep
- Create: `CasablancaTests/MeetingPrepServiceTests.swift`
  - Cover prep-path resolution and file-loading edge cases
- Modify: `Casablanca/Views/Components/MarkdownTextEditor.swift`
  - Add `ToastMarkdownViewer` and viewer bundle URL lookup
- Create: `Casablanca/Resources/MarkdownEditor/viewer.html`
  - Dedicated read-only Toast UI viewer page
- Create: `Casablanca/Resources/MarkdownEditor/viewer-bridge.js`
  - Bridge for pushing Markdown into the viewer after the web view is ready
- Modify: `CasablancaTests/MarkdownEditorBundleTests.swift`
  - Assert the new viewer page is bundled
- Modify: `Casablanca/Views/NotesEditorView.swift`
  - Add prep-loading state, collapse/show controls, and split/full-width layout behavior
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
  - Add unit tests for prep presentation state
- Modify: `Casablanca.xcodeproj/project.pbxproj`
  - Add the new Swift source and test files to the app/test targets

### Task 1: Add Obsidian Prep Reader

**Files:**
- Create: `Casablanca/Services/MeetingPrepService.swift`
- Create: `CasablancaTests/MeetingPrepServiceTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import XCTest
@testable import Casablanca

final class MeetingPrepServiceTests: XCTestCase {
    func testPrepURLUsesMeetingNotesFolderAndPrepSuffix() {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.path-\(UUID().uuidString)")!
        defaults.set("/tmp/obsidian-vault", forKey: AppPreferenceKey.obsidianVaultPath)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        let prepURL = MeetingPrepService.prepURL(for: meeting, userDefaults: defaults)

        XCTAssertEqual(
            prepURL?.path,
            "/tmp/obsidian-vault/meeting notes/2026-04-12 Weekly Sync - Prep.md"
        )
    }

    func testLoadPrepMarkdownReturnsContentsWhenPrepFileExists() throws {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.exists-\(UUID().uuidString)")!
        let vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2026-04-12 Weekly Sync - Prep.md")
        try "# Agenda\n\n- Review roadmap".write(to: prepURL, atomically: true, encoding: .utf8)

        let markdown = MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults)

        XCTAssertEqual(markdown, "# Agenda\n\n- Review roadmap")
    }

    func testLoadPrepMarkdownReturnsNilWhenVaultPathMissing() {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.missing-vault-\(UUID().uuidString)")!
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        XCTAssertNil(MeetingPrepService.prepURL(for: meeting, userDefaults: defaults))
        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    func testLoadPrepMarkdownReturnsNilWhenPrepFileMissing() {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.missing-file-\(UUID().uuidString)")!
        defaults.set("/tmp/obsidian-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    private func makeDate() -> Date {
        Date(timeIntervalSince1970: 1_744_416_000) // 2026-04-12 00:00:00 UTC
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingPrepServiceTests
```

Expected: FAIL because `MeetingPrepServiceTests.swift` is not yet in the test target and `MeetingPrepService` does not exist.

- [ ] **Step 3: Write the minimal implementation**

```swift
import Foundation

enum MeetingPrepService {
    static func prepURL(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        let vaultPath = userDefaults.string(forKey: AppPreferenceKey.obsidianVaultPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !vaultPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent("meeting notes", isDirectory: true)
            .appendingPathComponent("\(meeting.obsidianFileName) - Prep.md")
    }

    static func loadPrepMarkdown(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        guard let prepURL = prepURL(for: meeting, userDefaults: userDefaults) else {
            return nil
        }

        guard let markdown = try? String(contentsOf: prepURL, encoding: .utf8) else {
            return nil
        }

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : markdown
    }
}
```

Add the new app/test files to `Casablanca.xcodeproj/project.pbxproj` so they are compiled by the `Casablanca` and `CasablancaTests` targets.

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingPrepServiceTests
```

Expected: PASS with 4 tests executed in `MeetingPrepServiceTests`.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/MeetingPrepService.swift CasablancaTests/MeetingPrepServiceTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat: add meeting prep file loader"
```

### Task 2: Add Read-Only Markdown Viewer

**Files:**
- Modify: `Casablanca/Views/Components/MarkdownTextEditor.swift`
- Create: `Casablanca/Resources/MarkdownEditor/viewer.html`
- Create: `Casablanca/Resources/MarkdownEditor/viewer-bridge.js`
- Modify: `CasablancaTests/MarkdownEditorBundleTests.swift`

- [ ] **Step 1: Write the failing bundle test**

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MarkdownEditorBundleTests
```

Expected: FAIL because `ToastMarkdownViewer` and the new viewer resources do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Add a dedicated viewer representable to `Casablanca/Views/Components/MarkdownTextEditor.swift`:

```swift
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
            webView.loadHTMLString("<html><body>Missing bundled markdown viewer assets.</body></html>", baseURL: nil)
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
```

Expose the string-encoding helper in the existing editor coordinator by changing:

```swift
private static func javaScriptStringLiteral(_ value: String) -> String
```

to:

```swift
static func javaScriptStringLiteral(_ value: String) -> String
```

Create `Casablanca/Resources/MarkdownEditor/viewer.html`:

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="toastui-editor.min.css">
  <style>
    html, body, #viewer {
      margin: 0;
      width: 100%;
      height: 100%;
      background: transparent;
    }

    body {
      color: #1f2937;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      overflow: auto;
    }

    .toastui-editor-contents {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      font-size: 14px;
      line-height: 1.55;
      padding: 0;
    }
  </style>
</head>
<body>
  <div id="viewer"></div>
  <script src="toastui-editor-all.min.js"></script>
  <script src="viewer-bridge.js"></script>
</body>
</html>
```

Create `Casablanca/Resources/MarkdownEditor/viewer-bridge.js`:

```javascript
(() => {
  const messageHandler = window.webkit?.messageHandlers?.casablancaViewer;
  const post = (type) => messageHandler?.postMessage({ type });

  const viewer = toastui.Editor.factory({
    el: document.querySelector('#viewer'),
    viewer: true,
    initialValue: '',
    usageStatistics: false
  });

  window.CasablancaViewer = {
    setMarkdown(markdown) {
      viewer.setMarkdown(markdown ?? '');
    }
  };

  post('ready');
})();
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MarkdownEditorBundleTests
```

Expected: PASS with both the editor and viewer bundle tests green.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Views/Components/MarkdownTextEditor.swift Casablanca/Resources/MarkdownEditor/viewer.html Casablanca/Resources/MarkdownEditor/viewer-bridge.js CasablancaTests/MarkdownEditorBundleTests.swift
git commit -m "feat: add read-only markdown viewer"
```

### Task 3: Add Prep Layout State and Notes Workspace UI

**Files:**
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing presentation tests**

Append these tests to `MeetingStartFlowTests.swift`:

```swift
@MainActor
final class MeetingPrepPresentationTests: XCTestCase {
    func testPrepPaneShowsWhenMarkdownExistsAndExpanded() {
        let presentation = MeetingPrepPresentation(
            markdown: "# Prep",
            isExpanded: true
        )

        XCTAssertTrue(presentation.hasPrep)
        XCTAssertTrue(presentation.showsPrepPane)
        XCTAssertFalse(presentation.showsShowPrepButton)
    }

    func testPrepPaneCollapseShowsRevealButton() {
        let presentation = MeetingPrepPresentation(
            markdown: "# Prep",
            isExpanded: false
        )

        XCTAssertTrue(presentation.hasPrep)
        XCTAssertFalse(presentation.showsPrepPane)
        XCTAssertTrue(presentation.showsShowPrepButton)
    }

    func testEmptyMarkdownBehavesLikeNoPrep() {
        let presentation = MeetingPrepPresentation(
            markdown: "   \n",
            isExpanded: true
        )

        XCTAssertFalse(presentation.hasPrep)
        XCTAssertFalse(presentation.showsPrepPane)
        XCTAssertFalse(presentation.showsShowPrepButton)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests
```

Expected: FAIL because `MeetingPrepPresentation` does not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Add a prep presentation helper near `MeetingWorkspacePresentation` in `Casablanca/Views/NotesEditorView.swift`:

```swift
struct MeetingPrepPresentation: Equatable {
    let markdown: String?
    let isExpanded: Bool

    var hasPrep: Bool {
        !(markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var showsPrepPane: Bool {
        hasPrep && isExpanded
    }

    var showsShowPrepButton: Bool {
        hasPrep && !isExpanded
    }

    var markdownText: String {
        markdown ?? ""
    }
}
```

Add local prep state to `NotesEditorView`:

```swift
@State private var prepMarkdown: String?
@State private var isPrepExpanded = false
```

Add a computed prep presentation:

```swift
private var prepPresentation: MeetingPrepPresentation {
    MeetingPrepPresentation(
        markdown: prepMarkdown,
        isExpanded: isPrepExpanded
    )
}
```

Load prep content when the meeting changes:

```swift
.task(id: meeting.id) {
    loadPrepMarkdown()
}
```

```swift
private func loadPrepMarkdown() {
    let markdown = MeetingPrepService.loadPrepMarkdown(for: meeting)
    prepMarkdown = markdown
    isPrepExpanded = markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
}
```

Refactor the freeform workspace so recording keeps the to-do column, while prep lives beside the notes column:

```swift
@ViewBuilder
private var freeformWorkspace: some View {
    if presentation.showsRecordingChrome {
        HStack(spacing: 0) {
            prepAwareNotesWorkspace
            Divider()
            todosArea.frame(width: 260)
        }
    } else {
        prepAwareNotesWorkspace
    }
}

@ViewBuilder
private var prepAwareNotesWorkspace: some View {
    if prepPresentation.showsPrepPane {
        HStack(spacing: 0) {
            prepPane
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)

            Divider()
            notesColumn
        }
    } else {
        notesColumn
    }
}

private var notesColumn: some View {
    VStack(spacing: 0) {
        if prepPresentation.showsShowPrepButton {
            notesHeader
            Divider()
        }

        freeformNotesEditor
    }
}
```

Add the prep-pane and reveal controls:

```swift
private var prepPane: some View {
    VStack(spacing: 0) {
        HStack(spacing: CasaSpace.sm) {
            Text("Preparation")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Button {
                isPrepExpanded = false
            } label: {
                Label("Hide Prep", systemImage: "sidebar.left")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.md)

        Divider()

        ToastMarkdownViewer(markdown: prepPresentation.markdownText)
            .padding(CasaSpace.lg)
    }
}

private var notesHeader: some View {
    HStack {
        Spacer()

        Button {
            isPrepExpanded = true
        } label: {
            Label("Show Prep", systemImage: "sidebar.left")
        }
        .buttonStyle(.plain)
    }
    .padding(.horizontal, CasaSpace.lg)
    .padding(.vertical, CasaSpace.md)
}
```

Leave `freeformNotesEditor`, `meeting.userNotes`, export, and timestamped mode unchanged so prep remains read-only and separate from app-authored notes.

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests -only-testing:CasablancaTests/MeetingPrepServiceTests -only-testing:CasablancaTests/MarkdownEditorBundleTests
```

Expected: PASS with the new prep-presentation tests green and no regressions in the existing workspace-flow tests.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Views/NotesEditorView.swift CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: show meeting prep beside notes"
```

### Task 4: Full Verification

**Files:**
- Modify: none
- Test: `CasablancaTests/MeetingPrepServiceTests.swift`
- Test: `CasablancaTests/MarkdownEditorBundleTests.swift`
- Test: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Run the focused regression suite**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingPrepServiceTests -only-testing:CasablancaTests/MarkdownEditorBundleTests -only-testing:CasablancaTests/MeetingStartFlowTests
```

Expected: PASS for the prep reader, viewer bundle, and workspace presentation tests.

- [ ] **Step 2: Run the full test suite**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'
```

Expected: PASS with the full `CasablancaTests` suite green.

- [ ] **Step 3: Verify the user-facing behavior manually**

1. Launch the app from Xcode using the `Casablanca` scheme.
2. Set an Obsidian vault path in Settings.
3. Create a file named `meeting notes/2026-04-12 Weekly Sync - Prep.md` inside that vault with:

````md
# Weekly Sync

> Bring the Q2 roadmap draft

- Review launch risks
- Confirm owners

```swift
print("demo code block")
```
````

4. Open the matching meeting in the app.
5. Confirm:
   - the prep pane starts expanded
   - headings, blockquote, list, and code block are rendered as Markdown, not raw source
   - collapsing prep makes the notes editor full width
   - clicking `Show Prep` restores the split layout
   - editing live notes does not modify the prep file

- [ ] **Step 4: Commit the final verification checkpoint**

```bash
git status --short
```

Expected: clean working tree.

If clean:

```bash
git commit --allow-empty -m "test: verify meeting prep workspace flow"
```

If additional fixes were needed during verification, commit those real changes instead of using `--allow-empty`.
