# Apple Notes Export and Local Prep/Todos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two independent Settings — `Export destination` (Obsidian / Apple Notes) and `Prep/todo storage` (Obsidian / Local) — so meeting export and prep/todo storage can be retargeted without touching the Obsidian vault.

**Architecture:** Two preferences gate a thin routing layer. `ExportService` becomes a switch over two exporters: the existing logic extracted to `ObsidianMeetingExporter`, and a new `AppleNotesMeetingExporter` that talks to Apple Notes via an `AppleNotesScripting` protocol with an `NSAppleScript`-backed production implementation and an in-memory fake for tests. `MeetingPrepService` and `ObsidianTodoSyncService` gate on the storage preference; in Local mode, SwiftData is the sole source of truth.

**Tech Stack:** Swift, SwiftUI, SwiftData, XCTest, `NSAppleScript`, AppleScript (Notes scripting dictionary), macOS App Sandbox.

**Spec reference:** `docs/superpowers/specs/2026-04-13-apple-notes-export-and-local-prep-todos-design.md`.

**Test command template** (used throughout):

```bash
xcodebuild test -project Casablanca.xcodeproj \
  -scheme Casablanca \
  -derivedDataPath .build/test \
  -destination 'platform=macOS' \
  -only-testing:CasablancaTests/<TestClass>/<testMethod> \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Use `-only-testing:CasablancaTests/<TestClass>` (no method) to run a whole class. Omit `-only-testing` for the full suite.

---

## Task 1: Add `ExportDestination` and `PrepTodoStorage` preferences with migration

**Files:**
- Modify: `Casablanca/Models/Meeting.swift` (`AppPreferenceKey` enum, top of file)
- Create: `Casablanca/Models/AppPreferences.swift`
- Create: `CasablancaTests/AppPreferencesTests.swift`

- [ ] **Step 1: Write failing tests for the preference enums and the legacy migration**

Create `CasablancaTests/AppPreferencesTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class AppPreferencesTests: XCTestCase {
    private func makeDefaults(suite: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testExportDestinationDefaultsToObsidian() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.exportDestination(in: defaults), .obsidian)
    }

    func testExportDestinationReadsStoredValue() {
        let defaults = makeDefaults()
        defaults.set("appleNotes", forKey: AppPreferenceKey.exportDestination)
        XCTAssertEqual(AppPreferences.exportDestination(in: defaults), .appleNotes)
    }

    func testPrepTodoStorageDefaultsToObsidian() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.prepTodoStorage(in: defaults), .obsidian)
    }

    func testPrepTodoStorageReadsStoredValue() {
        let defaults = makeDefaults()
        defaults.set("local", forKey: AppPreferenceKey.prepTodoStorage)
        XCTAssertEqual(AppPreferences.prepTodoStorage(in: defaults), .local)
    }

    func testAutoExportEnabledMigratesFromLegacyKey() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian)
        XCTAssertNil(defaults.object(forKey: AppPreferenceKey.autoExportEnabled))

        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: AppPreferenceKey.autoExportEnabled))
        // Legacy key is preserved (do not delete user data)
        XCTAssertTrue(defaults.bool(forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian))
    }

    func testAutoExportEnabledMigrationIsIdempotent() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian)
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)
        // User then turns it off
        defaults.set(false, forKey: AppPreferenceKey.autoExportEnabled)

        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)

        // Second migration must not overwrite the user's later choice
        XCTAssertFalse(defaults.bool(forKey: AppPreferenceKey.autoExportEnabled))
    }

    func testAutoExportEnabledMigrationSkippedWhenNoLegacyValue() {
        let defaults = makeDefaults()
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)
        XCTAssertNil(defaults.object(forKey: AppPreferenceKey.autoExportEnabled))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/AppPreferencesTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: Compile failure ("Cannot find 'AppPreferences' in scope" and missing `AppPreferenceKey.exportDestination`, `.prepTodoStorage`, `.autoExportEnabled`, `.legacyAutoExportNotesToObsidian`).

- [ ] **Step 3: Add the new preference keys and enums**

In `Casablanca/Models/Meeting.swift`, replace the `AppPreferenceKey` enum body so it reads:

```swift
enum AppPreferenceKey {
    static let obsidianVaultPath = "obsidianVaultPath"
    static let ollamaEndpoint = "ollamaEndpoint"
    static let ollamaModel = "ollamaModel"
    static let whisperModel = "whisperModel"
    static let defaultTranscriptionLanguage = "defaultTranscriptionLanguage"
    static let summaryPromptTemplate = "summaryPromptTemplate"
    static let autoExportEnabled = "autoExportEnabled"
    static let legacyAutoExportNotesToObsidian = "autoExportNotesToObsidian"
    static let autoSummarizeAfterTranscription = "autoSummarizeAfterTranscription"
    static let defaultRecordingInputDeviceID = "defaultRecordingInputDeviceID"
    static let recordingWorkspaceFocusMode = "recordingWorkspaceFocusMode"
    static let terminologyCorrectionEnabled = "terminologyCorrectionEnabled"
    static let terminologyList = "terminologyList"
    static let exportDestination = "exportDestination"
    static let prepTodoStorage = "prepTodoStorage"
}
```

Note: the previous `autoExportNotesToObsidian` constant is renamed to `legacyAutoExportNotesToObsidian` and a new `autoExportEnabled` is added. Call sites using `autoExportNotesToObsidian` will be updated in Task 11.

Create `Casablanca/Models/AppPreferences.swift`:

```swift
import Foundation

enum ExportDestination: String {
    case obsidian
    case appleNotes
}

enum PrepTodoStorage: String {
    case obsidian
    case local
}

enum AppPreferences {
    static func exportDestination(in defaults: UserDefaults = .standard) -> ExportDestination {
        let raw = defaults.string(forKey: AppPreferenceKey.exportDestination) ?? ""
        return ExportDestination(rawValue: raw) ?? .obsidian
    }

    static func setExportDestination(_ value: ExportDestination, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppPreferenceKey.exportDestination)
    }

    static func prepTodoStorage(in defaults: UserDefaults = .standard) -> PrepTodoStorage {
        let raw = defaults.string(forKey: AppPreferenceKey.prepTodoStorage) ?? ""
        return PrepTodoStorage(rawValue: raw) ?? .obsidian
    }

    static func setPrepTodoStorage(_ value: PrepTodoStorage, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
    }

    static func autoExportEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.autoExportEnabled)
    }

    /// One-shot migration: if the legacy `autoExportNotesToObsidian` key has a value but the new
    /// `autoExportEnabled` key has none, seed the new key from the legacy value. The legacy key is
    /// preserved (do not delete user data). Idempotent: subsequent calls are no-ops once the new
    /// key exists.
    static func migrateLegacyAutoExportKeyIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: AppPreferenceKey.autoExportEnabled) == nil else { return }
        guard let legacyValue = defaults.object(forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian) as? Bool else {
            return
        }
        defaults.set(legacyValue, forKey: AppPreferenceKey.autoExportEnabled)
    }
}
```

Add the file to the `Casablanca` target in the Xcode project (it must be in the `Sources` build phase).

- [ ] **Step 4: Run tests to verify they pass**

Run the same command as Step 2. Expected: all `AppPreferencesTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Models/Meeting.swift Casablanca/Models/AppPreferences.swift CasablancaTests/AppPreferencesTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(prefs): add ExportDestination and PrepTodoStorage preferences with legacy migration"
```

---

## Task 2: Add Apple Notes id cache properties on `Meeting`

**Files:**
- Modify: `Casablanca/Models/Meeting.swift` (the `@Model final class Meeting` body)

This is a pure additive SwiftData schema change. SwiftData lightweight migration handles new optional properties automatically. No test required — a build verification is sufficient.

- [ ] **Step 1: Add the two optional properties**

In `Casablanca/Models/Meeting.swift`, inside `final class Meeting`, add the two properties after `var transcriptionLanguage`:

```swift
    var appleNotesSummaryNoteId: String?
    var appleNotesRawNotesNoteId: String?
```

Do not modify the `init`; the default `nil` values are fine for existing rows.

- [ ] **Step 2: Build to verify the schema change compiles**

```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/Models/Meeting.swift
git commit -m "feat(model): cache Apple Notes note ids on Meeting"
```

---

## Task 3: Define `AppleNotesScripting` protocol and in-memory fake

**Files:**
- Create: `Casablanca/Services/AppleNotesScripting.swift`
- Create: `CasablancaTests/Fixtures/InMemoryAppleNotesScripting.swift`
- Create: `CasablancaTests/AppleNotesScriptingFakeTests.swift`

- [ ] **Step 1: Write a failing test for the in-memory fake's basic behavior**

Create `CasablancaTests/AppleNotesScriptingFakeTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class AppleNotesScriptingFakeTests: XCTestCase {
    func testEnsureFolderIsIdempotent() async throws {
        let fake = InMemoryAppleNotesScripting()
        let first = try await fake.ensureFolder(named: "Casablanca")
        let second = try await fake.ensureFolder(named: "Casablanca")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(fake.folders.count, 1)
    }

    func testCreateNotePersistsAndReturnsRef() async throws {
        let fake = InMemoryAppleNotesScripting()
        let folder = try await fake.ensureFolder(named: "Casablanca")
        let ref = try await fake.createNote(title: "Hello", body: "<html><body><p>hi</p></body></html>", in: folder)
        XCTAssertFalse(ref.id.isEmpty)
        let body = try await fake.noteBody(id: ref.id)
        XCTAssertEqual(body, "<html><body><p>hi</p></body></html>")
    }

    func testFindNoteMatchesMarkerSubstring() async throws {
        let fake = InMemoryAppleNotesScripting()
        let folder = try await fake.ensureFolder(named: "Casablanca")
        _ = try await fake.createNote(title: "A", body: "<p>Casablanca id: 11111111-1111-1111-1111-111111111111 / summary</p>", in: folder)
        _ = try await fake.createNote(title: "B", body: "<p>nope</p>", in: folder)

        let match = try await fake.findNote(markerContaining: "11111111-1111-1111-1111-111111111111 / summary", in: folder)
        XCTAssertEqual(match?.title, "A")
    }

    func testUpdateNoteReplacesBody() async throws {
        let fake = InMemoryAppleNotesScripting()
        let folder = try await fake.ensureFolder(named: "Casablanca")
        let ref = try await fake.createNote(title: "T", body: "<p>old</p>", in: folder)

        try await fake.updateNote(id: ref.id, title: "T2", body: "<p>new</p>")

        let body = try await fake.noteBody(id: ref.id)
        XCTAssertEqual(body, "<p>new</p>")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/AppleNotesScriptingFakeTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: Compile failure ("Cannot find 'InMemoryAppleNotesScripting'", "Cannot find 'AppleNotesScripting'").

- [ ] **Step 3: Create the protocol, value types, and fake**

Create `Casablanca/Services/AppleNotesScripting.swift`:

```swift
import Foundation

struct AppleNotesFolderRef: Equatable {
    let id: String
    let name: String
}

struct AppleNotesNoteRef: Equatable {
    let id: String
    let title: String
}

protocol AppleNotesScripting {
    func ensureFolder(named name: String) async throws -> AppleNotesFolderRef
    func findNote(markerContaining marker: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef?
    func noteBody(id: String) async throws -> String?
    func createNote(title: String, body: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef
    func updateNote(id: String, title: String, body: String) async throws
}
```

Create `CasablancaTests/Fixtures/InMemoryAppleNotesScripting.swift`:

```swift
import Foundation
@testable import Casablanca

final actor InMemoryAppleNotesScripting: AppleNotesScripting {
    struct StoredNote {
        var id: String
        var title: String
        var body: String
        var folderId: String
    }

    private(set) var folders: [AppleNotesFolderRef] = []
    private(set) var notes: [StoredNote] = []
    private(set) var calls: [String] = []
    var ensureFolderError: Error?
    var createNoteError: Error?
    var updateNoteError: Error?
    var findNoteError: Error?
    var noteBodyError: Error?

    func setEnsureFolderError(_ error: Error?) { ensureFolderError = error }
    func setCreateNoteError(_ error: Error?) { createNoteError = error }
    func setUpdateNoteError(_ error: Error?) { updateNoteError = error }
    func setFindNoteError(_ error: Error?) { findNoteError = error }
    func setNoteBodyError(_ error: Error?) { noteBodyError = error }

    /// Simulate an out-of-band rewrite (e.g. user deletes/renames the folder in Notes).
    func removeFolder(named name: String) {
        if let folder = folders.first(where: { $0.name == name }) {
            folders.removeAll { $0.id == folder.id }
            notes.removeAll { $0.folderId == folder.id }
        }
    }

    func ensureFolder(named name: String) async throws -> AppleNotesFolderRef {
        calls.append("ensureFolder:\(name)")
        if let error = ensureFolderError { throw error }
        if let existing = folders.first(where: { $0.name == name }) { return existing }
        let folder = AppleNotesFolderRef(id: "folder-\(folders.count + 1)", name: name)
        folders.append(folder)
        return folder
    }

    func findNote(markerContaining marker: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef? {
        calls.append("findNote:\(marker):\(folder.id)")
        if let error = findNoteError { throw error }
        if let note = notes.first(where: { $0.folderId == folder.id && $0.body.contains(marker) }) {
            return AppleNotesNoteRef(id: note.id, title: note.title)
        }
        return nil
    }

    func noteBody(id: String) async throws -> String? {
        calls.append("noteBody:\(id)")
        if let error = noteBodyError { throw error }
        return notes.first(where: { $0.id == id })?.body
    }

    func createNote(title: String, body: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef {
        calls.append("createNote:\(title):\(folder.id)")
        if let error = createNoteError { throw error }
        let note = StoredNote(id: "note-\(notes.count + 1)", title: title, body: body, folderId: folder.id)
        notes.append(note)
        return AppleNotesNoteRef(id: note.id, title: note.title)
    }

    func updateNote(id: String, title: String, body: String) async throws {
        calls.append("updateNote:\(id)")
        if let error = updateNoteError { throw error }
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "InMemoryAppleNotesScripting", code: 404, userInfo: [NSLocalizedDescriptionKey: "Note not found"])
        }
        notes[index].title = title
        notes[index].body = body
    }
}
```

Add both files to the appropriate targets (`Casablanca` target for `AppleNotesScripting.swift`, `CasablancaTests` target for the fake).

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/AppleNotesScripting.swift CasablancaTests/Fixtures/InMemoryAppleNotesScripting.swift CasablancaTests/AppleNotesScriptingFakeTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(apple-notes): add scripting protocol and in-memory fake"
```

---

## Task 4: Implement `AppleNotesBodyRenderer` (HTML rendering)

**Files:**
- Create: `Casablanca/Services/AppleNotesBodyRenderer.swift`
- Create: `CasablancaTests/AppleNotesBodyRendererTests.swift`

Renderer is a pure function from `Meeting` → HTML strings (summary HTML and raw-notes HTML). It uses the limited Notes-preserved tag subset documented in the spec.

- [ ] **Step 1: Write failing tests**

Create `CasablancaTests/AppleNotesBodyRendererTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class AppleNotesBodyRendererTests: XCTestCase {
    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Freeform notes go here."
        meeting.timestampedNotes = [TimestampedNote(timestamp: 65, text: "Discussed rollout plan")]
        meeting.summary = "We agreed on next steps."
        let todoOpen = TodoItem(text: "Send recap", isCompleted: false)
        let todoDone = TodoItem(text: "Book room", isCompleted: true)
        meeting.todos = [todoOpen, todoDone]
        return meeting
    }

    func testSummaryWrapsInHTMLDocument() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertTrue(html.hasPrefix("<html><body>"))
        XCTAssertTrue(html.hasSuffix("</body></html>"))
    }

    func testSummaryStripsYAMLFrontmatter() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertFalse(html.contains("---"))
        XCTAssertFalse(html.contains("casablanca_type"))
    }

    func testSummaryFlattensWikilinks() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertFalse(html.contains("[["))
        XCTAssertFalse(html.contains("]]"))
    }

    func testSummaryRendersTodosWithGlyphs() {
        let html = AppleNotesBodyRenderer.summaryHTML(for: makeMeeting())
        XCTAssertTrue(html.contains("<li>☐ Send recap</li>"))
        XCTAssertTrue(html.contains("<li>☑ Book room</li>"))
    }

    func testSummaryEmbedsMarkerInTrailingParagraph() {
        let meeting = makeMeeting()
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        let expectedMarker = "Casablanca id: \(meeting.id.uuidString) / summary"
        XCTAssertTrue(html.contains("<p>\(expectedMarker)</p></body></html>"),
            "Marker should be the last <p> before </body>; got: \(html)")
    }

    func testRawNotesEmbedsNotesMarker() {
        let meeting = makeMeeting()
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        let expectedMarker = "Casablanca id: \(meeting.id.uuidString) / notes"
        XCTAssertTrue(html.contains("<p>\(expectedMarker)</p></body></html>"))
    }

    func testRawNotesContainsFreeformAndTimestampedSections() {
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: makeMeeting())
        XCTAssertTrue(html.contains("Freeform Notes"))
        XCTAssertTrue(html.contains("Freeform notes go here."))
        XCTAssertTrue(html.contains("Timestamped Notes"))
        XCTAssertTrue(html.contains("[01:05] Discussed rollout plan"))
    }

    func testHTMLEscapesUserContent() {
        let meeting = Meeting(title: "<script>alert(1)</script>", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "5 < 6 & 7 > 4"
        meeting.summary = nil
        let html = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("5 &lt; 6 &amp; 7 &gt; 4"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testSummaryOmittedWhenSummaryIsEmpty() {
        let meeting = makeMeeting()
        meeting.summary = "  "
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        // Summary section should still render headers; we just verify no crash and marker is present.
        XCTAssertTrue(html.contains("Casablanca id:"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/AppleNotesBodyRendererTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: Compile failure ("Cannot find 'AppleNotesBodyRenderer' in scope").

- [ ] **Step 3: Implement the renderer**

Create `Casablanca/Services/AppleNotesBodyRenderer.swift`:

```swift
import Foundation

enum AppleNotesBodyRenderer {
    static func summaryHTML(for meeting: Meeting) -> String {
        var sections: [String] = []
        sections.append("<h1>\(escape(meeting.title))</h1>")
        sections.append(meetingFactsParagraphs(for: meeting))

        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty {
            sections.append("<h2>Summary</h2>")
            sections.append(paragraphs(from: summary))
        }

        if !meeting.todos.isEmpty {
            sections.append("<h2>Action Items</h2>")
            sections.append(todoList(meeting.todos))
        }

        sections.append(markerParagraph(meetingId: meeting.id, kind: "summary"))
        return wrap(sections.joined())
    }

    static func rawNotesHTML(for meeting: Meeting) -> String {
        var sections: [String] = []
        sections.append("<h1>\(escape(meeting.title)) - Raw Notes</h1>")
        sections.append(meetingFactsParagraphs(for: meeting))

        sections.append("<h2>Freeform Notes</h2>")
        let userNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if userNotes.isEmpty {
            sections.append("<p><i>No freeform notes captured.</i></p>")
        } else {
            sections.append(paragraphs(from: userNotes))
        }

        if !meeting.timestampedNotes.isEmpty {
            sections.append("<h2>Timestamped Notes</h2>")
            let items = meeting.timestampedNotes.map { note in
                "<li>[\(escape(note.formattedTimestamp))] \(escape(note.text))</li>"
            }.joined()
            sections.append("<ul>\(items)</ul>")
        }

        sections.append(markerParagraph(meetingId: meeting.id, kind: "notes"))
        return wrap(sections.joined())
    }

    // MARK: - Helpers

    private static func wrap(_ body: String) -> String {
        "<html><body>\(body)</body></html>"
    }

    private static func markerParagraph(meetingId: UUID, kind: String) -> String {
        // Visible footer marker — Notes is known to strip HTML comments on save, so the marker
        // is rendered as plain text inside a trailing <p>.
        "<p>Casablanca id: \(meetingId.uuidString) / \(kind)</p>"
    }

    private static func meetingFactsParagraphs(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let scheduled = formatter.string(from: meeting.date)
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let participantsText = participants.isEmpty ? "Not captured." : participants.joined(separator: ", ")
        let recordingText = meeting.recordingDuration.map(formatDuration) ?? "Not recorded."

        return """
        <ul>\
        <li>Scheduled: \(escape(scheduled))</li>\
        <li>Participants: \(escape(participantsText))</li>\
        <li>Recording: \(escape(recordingText))</li>\
        </ul>
        """
    }

    private static func todoList(_ todos: [TodoItem]) -> String {
        let items = todos.map { todo in
            let glyph = todo.isCompleted ? "☑" : "☐"
            return "<li>\(glyph) \(escape(todo.text))</li>"
        }.joined()
        return "<ul>\(items)</ul>"
    }

    private static func paragraphs(from text: String) -> String {
        text.split(separator: "\n\n", omittingEmptySubsequences: false)
            .map { "<p>\(escape(stripWikilinks(String($0))))</p>" }
            .joined()
    }

    private static func stripWikilinks(_ text: String) -> String {
        var result = text
        while let openRange = result.range(of: "[["),
              let closeRange = result.range(of: "]]", range: openRange.upperBound..<result.endIndex) {
            let inner = String(result[openRange.upperBound..<closeRange.lowerBound])
            result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: inner)
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }
}
```

Add to the `Casablanca` target.

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/AppleNotesBodyRenderer.swift CasablancaTests/AppleNotesBodyRendererTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(apple-notes): add HTML body renderer for summary and raw notes"
```

---

## Task 5: Add `AppleNotesExportError` enum with error-code mapping

**Files:**
- Create: `Casablanca/Services/AppleNotesExportError.swift`
- Create: `CasablancaTests/AppleNotesExportErrorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `CasablancaTests/AppleNotesExportErrorTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class AppleNotesExportErrorTests: XCTestCase {
    func testMapsKnownPermissionErrorCodes() {
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -1743), .permissionDenied)
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -1744), .permissionDenied)
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -600), .permissionDenied)
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -10810), .permissionDenied)
    }

    func testMapsUnknownErrorCode() {
        switch AppleNotesExportError.from(appleScriptErrorCode: -42) {
        case .scriptingFailed(let code, _):
            XCTAssertEqual(code, -42)
        default:
            XCTFail("Expected scriptingFailed")
        }
    }

    func testPermissionDeniedMessageMentionsSystemSettings() {
        let message = AppleNotesExportError.permissionDenied.errorDescription ?? ""
        XCTAssertTrue(message.contains("System Settings"))
        XCTAssertTrue(message.contains("Automation"))
    }

    func testTimeoutMessageMentionsTimeout() {
        XCTAssertTrue((AppleNotesExportError.timedOut.errorDescription ?? "").lowercased().contains("timed out"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/AppleNotesExportErrorTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: Compile failure ("Cannot find 'AppleNotesExportError'").

- [ ] **Step 3: Implement the error type**

Create `Casablanca/Services/AppleNotesExportError.swift`:

```swift
import Foundation

enum AppleNotesExportError: LocalizedError, Equatable {
    case permissionDenied
    case timedOut
    case scriptingFailed(code: Int, message: String)
    case unexpectedResponse(String)

    static func from(appleScriptErrorCode code: Int, message: String = "") -> AppleNotesExportError {
        switch code {
        case -1743, -1744, -600, -10810:
            return .permissionDenied
        default:
            return .scriptingFailed(code: code, message: message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Casablanca isn't allowed to control Notes. Enable it under System Settings → Privacy & Security → Automation → Casablanca → Notes, then try again."
        case .timedOut:
            return "The Apple Notes export timed out. Try again or check that Notes is responsive."
        case .scriptingFailed(let code, let message):
            return "Apple Notes export failed (\(code)): \(message)"
        case .unexpectedResponse(let detail):
            return "Apple Notes returned an unexpected response: \(detail)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/AppleNotesExportError.swift CasablancaTests/AppleNotesExportErrorTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(apple-notes): add export error type and error-code mapping"
```

---

## Task 6: Implement `AppleNotesMeetingExporter` (upsert orchestration)

**Files:**
- Create: `Casablanca/Services/AppleNotesMeetingExporter.swift`
- Create: `CasablancaTests/AppleNotesMeetingExporterTests.swift`

The exporter orchestrates: resolve folder → resolve note (cached id → verify body → marker scan → create) → write back ids.

- [ ] **Step 1: Write failing tests**

Create `CasablancaTests/AppleNotesMeetingExporterTests.swift`:

```swift
import XCTest
@testable import Casablanca

@MainActor
final class AppleNotesMeetingExporterTests: XCTestCase {
    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Notes."
        meeting.summary = "Summary."
        return meeting
    }

    func testFirstExportCreatesFolderAndBothNotes() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        let result = try await exporter.export(meeting)

        let folders = await fake.folders
        XCTAssertEqual(folders.map(\.name), ["Casablanca"])
        let notes = await fake.notes
        XCTAssertEqual(notes.count, 2)
        XCTAssertNotNil(result.summaryNoteId)
        XCTAssertNotNil(result.rawNotesNoteId)
        XCTAssertEqual(meeting.appleNotesSummaryNoteId, result.summaryNoteId)
        XCTAssertEqual(meeting.appleNotesRawNotesNoteId, result.rawNotesNoteId)
    }

    func testReExportUpdatesExistingNotesAndDoesNotDuplicate() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        _ = try await exporter.export(meeting)
        meeting.summary = "Updated summary."
        _ = try await exporter.export(meeting)

        let notes = await fake.notes
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.body.contains("Updated summary.") })
    }

    func testReExportAfterClearedCacheFallsBackToMarkerScan() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        _ = try await exporter.export(meeting)
        let originalNoteCount = await fake.notes.count
        meeting.appleNotesSummaryNoteId = nil
        meeting.appleNotesRawNotesNoteId = nil

        _ = try await exporter.export(meeting)

        let finalCount = await fake.notes.count
        XCTAssertEqual(originalNoteCount, 2)
        XCTAssertEqual(finalCount, 2, "Marker scan should reuse existing notes")
        XCTAssertNotNil(meeting.appleNotesSummaryNoteId, "Resolved id should be written back")
    }

    func testStaleCachedIdPointingToUnrelatedNoteForcesScan() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()
        _ = try await exporter.export(meeting)

        // Simulate id drift: cached id now points at a body without the meeting's marker.
        let cachedId = meeting.appleNotesSummaryNoteId!
        try await fake.updateNote(id: cachedId, title: "Stranger", body: "<p>unrelated</p>")

        _ = try await exporter.export(meeting)

        let notes = await fake.notes
        // The unrelated note should still exist (we did NOT overwrite it), and the meeting should
        // have a fresh note created or the marker-matching note resolved.
        XCTAssertTrue(notes.contains { $0.id == cachedId && $0.body == "<p>unrelated</p>" },
            "Stale cache must not overwrite the unrelated note")
    }

    func testFolderDeletedOutOfBandIsRecreated() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()
        _ = try await exporter.export(meeting)

        await fake.removeFolder(named: "Casablanca")
        XCTAssertEqual(await fake.folders.count, 0)

        _ = try await exporter.export(meeting)

        XCTAssertEqual(await fake.folders.count, 1)
        XCTAssertEqual(await fake.notes.count, 2)
    }

    func testPermissionDeniedErrorPropagatesAsExportError() async throws {
        let fake = InMemoryAppleNotesScripting()
        await fake.setEnsureFolderError(NSError(
            domain: "NSAppleScriptErrorDomain",
            code: 0,
            userInfo: ["NSAppleScriptErrorNumber": -1743]
        ))
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        do {
            _ = try await exporter.export(meeting)
            XCTFail("Expected throw")
        } catch let error as AppleNotesExportError {
            XCTAssertEqual(error, .permissionDenied)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/AppleNotesMeetingExporterTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: Compile failure ("Cannot find 'AppleNotesMeetingExporter'").

- [ ] **Step 3: Implement the exporter**

Create `Casablanca/Services/AppleNotesMeetingExporter.swift`:

```swift
import Foundation

struct AppleNotesExportResult {
    let summaryNoteId: String?
    let rawNotesNoteId: String
}

final class AppleNotesMeetingExporter {
    static let folderName = "Casablanca"

    private let scripting: AppleNotesScripting

    init(scripting: AppleNotesScripting) {
        self.scripting = scripting
    }

    @discardableResult
    func export(_ meeting: Meeting) async throws -> AppleNotesExportResult {
        let folder = try await ensureFolderMappingErrors()

        let summaryHTML = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        let rawNotesHTML = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        let shouldExportSummary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let summaryMarker = "Casablanca id: \(meeting.id.uuidString) / summary"
        let notesMarker = "Casablanca id: \(meeting.id.uuidString) / notes"

        var summaryId: String? = nil
        if shouldExportSummary {
            summaryId = try await upsert(
                cachedId: meeting.appleNotesSummaryNoteId,
                marker: summaryMarker,
                title: meeting.obsidianFileName,
                body: summaryHTML,
                folder: folder
            )
            meeting.appleNotesSummaryNoteId = summaryId
        } else {
            meeting.appleNotesSummaryNoteId = nil
        }

        let rawNotesId = try await upsert(
            cachedId: meeting.appleNotesRawNotesNoteId,
            marker: notesMarker,
            title: "\(meeting.obsidianFileName) - Notes",
            body: rawNotesHTML,
            folder: folder
        )
        meeting.appleNotesRawNotesNoteId = rawNotesId

        return AppleNotesExportResult(summaryNoteId: summaryId, rawNotesNoteId: rawNotesId)
    }

    @discardableResult
    func exportRawNotesOnly(_ meeting: Meeting) async throws -> AppleNotesExportResult {
        let folder = try await ensureFolderMappingErrors()
        let rawNotesHTML = AppleNotesBodyRenderer.rawNotesHTML(for: meeting)
        let notesMarker = "Casablanca id: \(meeting.id.uuidString) / notes"

        let rawNotesId = try await upsert(
            cachedId: meeting.appleNotesRawNotesNoteId,
            marker: notesMarker,
            title: "\(meeting.obsidianFileName) - Notes",
            body: rawNotesHTML,
            folder: folder
        )
        meeting.appleNotesRawNotesNoteId = rawNotesId

        return AppleNotesExportResult(summaryNoteId: nil, rawNotesNoteId: rawNotesId)
    }

    private func ensureFolderMappingErrors() async throws -> AppleNotesFolderRef {
        do {
            return try await scripting.ensureFolder(named: Self.folderName)
        } catch {
            throw mapped(error)
        }
    }

    private func upsert(
        cachedId: String?,
        marker: String,
        title: String,
        body: String,
        folder: AppleNotesFolderRef
    ) async throws -> String {
        do {
            // 1. Cached id fast path with body verification.
            if let cachedId,
               let existingBody = try await scripting.noteBody(id: cachedId),
               existingBody.contains(marker) {
                try await scripting.updateNote(id: cachedId, title: title, body: body)
                return cachedId
            }

            // 2. Marker scan.
            if let match = try await scripting.findNote(markerContaining: marker, in: folder) {
                try await scripting.updateNote(id: match.id, title: title, body: body)
                return match.id
            }

            // 3. Create.
            let ref = try await scripting.createNote(title: title, body: body, in: folder)
            return ref.id
        } catch let error as AppleNotesExportError {
            throw error
        } catch {
            throw mapped(error)
        }
    }

    private func mapped(_ error: Error) -> Error {
        let nsError = error as NSError
        if let code = nsError.userInfo["NSAppleScriptErrorNumber"] as? Int {
            return AppleNotesExportError.from(appleScriptErrorCode: code, message: nsError.localizedDescription)
        }
        if nsError.domain == "NSAppleScriptErrorDomain", let code = nsError.userInfo["NSAppleScriptErrorNumber"] as? Int {
            return AppleNotesExportError.from(appleScriptErrorCode: code, message: nsError.localizedDescription)
        }
        return error
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/AppleNotesMeetingExporter.swift CasablancaTests/AppleNotesMeetingExporterTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(apple-notes): add meeting exporter with marker-based upsert"
```

---

## Task 7: Add `com.apple.security.automation.apple-events` entitlement and Info.plist key

**Files:**
- Modify: `Casablanca/Casablanca.entitlements`
- Modify: `Casablanca.xcodeproj/project.pbxproj` (search for `INFOPLIST_KEY_NSCalendarsUsageDescription`)

- [ ] **Step 1: Add the entitlement**

In `Casablanca/Casablanca.entitlements`, add inside the `<dict>`:

```xml
	<key>com.apple.security.automation.apple-events</key>
	<true/>
```

The full file should now look like:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.automation.apple-events</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.personal-information.calendars</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 2: Add the Info.plist usage description**

Open `Casablanca.xcodeproj/project.pbxproj` and locate **both** occurrences of:

```
INFOPLIST_KEY_NSCalendarsUsageDescription = "Casablanca needs access to your calendar to show upcoming meetings.";
```

(There are two: one in the Debug build config and one in Release.) Immediately above each occurrence, add a new line:

```
INFOPLIST_KEY_NSAppleEventsUsageDescription = "Casablanca uses AppleScript automation to save meeting notes to Apple Notes when you select Apple Notes as the export destination.";
```

- [ ] **Step 3: Build to verify the entitlement and Info.plist key compile and are recognized**

```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Casablanca.entitlements Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(entitlements): allow AppleEvents automation for Apple Notes export"
```

---

## Task 8: Implement `NSAppleScriptAppleNotesScripting` (production AppleScript backend)

**Files:**
- Create: `Casablanca/Services/NSAppleScriptAppleNotesScripting.swift`
- Create: `CasablancaTests/NSAppleScriptAppleNotesScriptingTests.swift` (compilation tests only — actual scripting requires the Notes app and user consent and is not run in CI)

This is the only task where the implementation cannot be fully unit-tested. The exporter logic is already covered by Task 6 via the fake. We add a thin production implementation that compiles AppleScript once, serializes execution, and surfaces error numbers.

- [ ] **Step 1: Write a compilation-only test that the production type exists and conforms to the protocol**

Create `CasablancaTests/NSAppleScriptAppleNotesScriptingTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class NSAppleScriptAppleNotesScriptingTests: XCTestCase {
    func testTypeConformsToProtocol() {
        // Smoke test: this only verifies the type exists and conforms.
        // Real scripting is exercised in manual integration testing per the spec.
        let scripting: AppleNotesScripting = NSAppleScriptAppleNotesScripting()
        XCTAssertNotNil(scripting)
    }

    func testTimeoutErrorIsMappedToAppleNotesExportError() {
        let nsError = NSError(domain: "NSAppleScriptErrorDomain", code: 0, userInfo: [
            "NSAppleScriptErrorNumber": -1712
        ])
        let mapped = AppleNotesExportError.from(appleScriptErrorCode: nsError.userInfo["NSAppleScriptErrorNumber"] as! Int)
        if case .scriptingFailed(let code, _) = mapped {
            XCTAssertEqual(code, -1712)
        } else {
            XCTFail("Expected scriptingFailed, got \(mapped)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/NSAppleScriptAppleNotesScriptingTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: Compile failure ("Cannot find 'NSAppleScriptAppleNotesScripting'").

- [ ] **Step 3: Implement the production scripting backend**

Create `Casablanca/Services/NSAppleScriptAppleNotesScripting.swift`:

```swift
import Foundation
import AppKit

final class NSAppleScriptAppleNotesScripting: AppleNotesScripting {
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.casablanca.AppleNotesScripting", qos: .userInitiated)

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func ensureFolder(named name: String) async throws -> AppleNotesFolderRef {
        let source = """
        tell application "Notes"
            set targetAccount to my __resolveAccount()
            set folderName to "\(escapeAppleScriptString(name))"
            if not (exists folder folderName of targetAccount) then
                make new folder at targetAccount with properties {name:folderName}
            end if
            set f to folder folderName of targetAccount
            return (id of f) & "||" & (name of f)
        end tell
        on __resolveAccount()
            tell application "Notes"
                try
                    return default account
                end try
                set acc to first account whose id is (id of first account)
                return acc
            end tell
        end __resolveAccount
        """
        let raw = try await run(source)
        let parts = raw.components(separatedBy: "||")
        guard parts.count == 2 else { throw AppleNotesExportError.unexpectedResponse(raw) }
        return AppleNotesFolderRef(id: parts[0], name: parts[1])
    }

    func findNote(markerContaining marker: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef? {
        let source = """
        tell application "Notes"
            set folderId to "\(escapeAppleScriptString(folder.id))"
            set markerText to "\(escapeAppleScriptString(marker))"
            set matches to {}
            try
                set theFolder to (first folder whose id is folderId)
            on error
                return ""
            end try
            repeat with n in (every note of theFolder)
                if (body of n) contains markerText then
                    return (id of n) & "||" & (name of n)
                end if
            end repeat
            return ""
        end tell
        """
        let raw = try await run(source)
        if raw.isEmpty { return nil }
        let parts = raw.components(separatedBy: "||")
        guard parts.count == 2 else { throw AppleNotesExportError.unexpectedResponse(raw) }
        return AppleNotesNoteRef(id: parts[0], title: parts[1])
    }

    func noteBody(id: String) async throws -> String? {
        let source = """
        tell application "Notes"
            try
                return body of (first note whose id is "\(escapeAppleScriptString(id))")
            on error
                return "__CASABLANCA_NOT_FOUND__"
            end try
        end tell
        """
        let raw = try await run(source)
        return raw == "__CASABLANCA_NOT_FOUND__" ? nil : raw
    }

    func createNote(title: String, body: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef {
        let source = """
        tell application "Notes"
            set folderId to "\(escapeAppleScriptString(folder.id))"
            set theFolder to (first folder whose id is folderId)
            set newNote to make new note at theFolder with properties {name:"\(escapeAppleScriptString(title))", body:"\(escapeAppleScriptString(body))"}
            return (id of newNote) & "||" & (name of newNote)
        end tell
        """
        let raw = try await run(source)
        let parts = raw.components(separatedBy: "||")
        guard parts.count == 2 else { throw AppleNotesExportError.unexpectedResponse(raw) }
        return AppleNotesNoteRef(id: parts[0], title: parts[1])
    }

    func updateNote(id: String, title: String, body: String) async throws {
        let source = """
        tell application "Notes"
            set theNote to (first note whose id is "\(escapeAppleScriptString(id))")
            set name of theNote to "\(escapeAppleScriptString(title))"
            set body of theNote to "\(escapeAppleScriptString(body))"
        end tell
        """
        _ = try await run(source)
    }

    // MARK: - Private

    private func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [timeout] in
                let group = DispatchGroup()
                var resultString: String?
                var error: Error?

                group.enter()
                let worker = Thread {
                    defer { group.leave() }
                    var errorInfo: NSDictionary?
                    guard let script = NSAppleScript(source: source) else {
                        error = AppleNotesExportError.unexpectedResponse("could not compile script")
                        return
                    }
                    let descriptor = script.executeAndReturnError(&errorInfo)
                    if let errorInfo = errorInfo {
                        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
                        error = AppleNotesExportError.from(appleScriptErrorCode: code, message: message)
                        return
                    }
                    resultString = descriptor.stringValue ?? ""
                }
                worker.start()

                if group.wait(timeout: .now() + timeout) == .timedOut {
                    continuation.resume(throwing: AppleNotesExportError.timedOut)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: resultString ?? "")
                }
            }
        }
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/NSAppleScriptAppleNotesScripting.swift CasablancaTests/NSAppleScriptAppleNotesScriptingTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(apple-notes): add NSAppleScript-backed scripting implementation"
```

---

## Task 9: Extract `ObsidianMeetingExporter` from `ExportService`

**Files:**
- Create: `Casablanca/Services/ObsidianMeetingExporter.swift`
- Modify: `Casablanca/Services/ExportService.swift`
- Existing tests in `CasablancaTests/ExportServiceTests.swift` must continue to pass without changes.

This is a pure refactor: move all the Obsidian-specific functions (`meetingNotesDirectory`, `rawNotesURL`, `summaryURL`, `summaryMarkdown`, `rawNotesMarkdown`, the participant/recording/duration helpers, `yamlEscaped`, `isoTimestamp`, `meetingDisplayDate`) into a new namespace `ObsidianMeetingExporter`. `ExportService` will retain `ExportResult`, `ExportError`, `hasExportableContent`, and a single static call into the extracted exporter.

- [ ] **Step 1: Run existing ExportService tests as a baseline**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ExportServiceTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: all tests currently pass. Record the count for comparison.

- [ ] **Step 2: Create `ObsidianMeetingExporter.swift`**

Create `Casablanca/Services/ObsidianMeetingExporter.swift` with the exact contents of the current Obsidian helpers, lifted from `ExportService.swift`:

```swift
import Foundation

enum ObsidianMeetingExporter {
    static func exportCompletedMeeting(_ meeting: Meeting) throws -> ExportResult {
        let directory = try meetingNotesDirectory()
        let notesURL = rawNotesURL(for: meeting, in: directory)
        let summaryURL = summaryURL(for: meeting, in: directory)
        let shouldExportSummary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        try rawNotesMarkdown(for: meeting, summaryFileName: shouldExportSummary ? summaryURL.deletingPathExtension().lastPathComponent : nil)
            .write(to: notesURL, atomically: true, encoding: .utf8)

        if shouldExportSummary {
            try summaryMarkdown(for: meeting, notesFileName: notesURL.deletingPathExtension().lastPathComponent)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        }

        return ExportResult(summaryURL: shouldExportSummary ? summaryURL : nil, notesURL: notesURL)
    }

    static func exportRawNotes(_ meeting: Meeting) throws -> ExportResult {
        let directory = try meetingNotesDirectory()
        let notesURL = rawNotesURL(for: meeting, in: directory)

        try rawNotesMarkdown(for: meeting, summaryFileName: nil)
            .write(to: notesURL, atomically: true, encoding: .utf8)

        return ExportResult(summaryURL: nil, notesURL: notesURL)
    }

    // MARK: - Private (moved verbatim from ExportService)

    private static func meetingNotesDirectory() throws -> URL {
        let vaultPath = UserDefaults.standard.string(forKey: AppPreferenceKey.obsidianVaultPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !vaultPath.isEmpty else {
            throw ExportError.missingVaultPath
        }

        let directory = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent("meeting notes", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func rawNotesURL(for meeting: Meeting, in directory: URL) -> URL {
        directory.appendingPathComponent("\(meeting.obsidianFileName) - Notes.md")
    }

    private static func summaryURL(for meeting: Meeting, in directory: URL) -> URL {
        directory.appendingPathComponent("\(meeting.obsidianFileName).md")
    }

    private static func summaryMarkdown(for meeting: Meeting, notesFileName: String) -> String {
        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notesLink = "[[\(notesFileName)]]"
        let actionItemsSection = meeting.todos.isEmpty
            ? ""
            : "\n\n## Action Items\n\n" + meeting.todos.map { "- [\($0.isCompleted ? "x" : " ")] \($0.text)" }.joined(separator: "\n")

        return """
        ---
        title: \(yamlEscaped(meeting.obsidianFileName))
        meeting_title: \(yamlEscaped(meeting.title))
        meeting_date: \(yamlEscaped(isoTimestamp(meeting.date)))
        casablanca_type: "meeting-summary"
        raw_notes: \(yamlEscaped(notesLink))
        ---

        # Summary

        \(summary)\(actionItemsSection)

        ## Meeting

        - Scheduled: \(meetingDisplayDate(meeting))
        \(participantsLine(for: meeting))
        \(recordingLine(for: meeting))
        - Transcript: Saved locally by Casablanca.

        ## Raw Notes

        \(notesLink)
        """
    }

    private static func rawNotesMarkdown(for meeting: Meeting, summaryFileName: String?) -> String {
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedFreeformNotes = freeformNotes.isEmpty ? "_No freeform notes captured._" : freeformNotes
        let timestampedNotesSection = meeting.timestampedNotes.isEmpty
            ? ""
            : """

        ## Timestamped Notes

        \(meeting.timestampedNotes
            .map { "- [\($0.formattedTimestamp)] \($0.text)" }
            .joined(separator: "\n"))
        """
        let summaryLink = summaryFileName.map { "[[\($0)]]" } ?? "_Not exported yet._"

        return """
        ---
        title: \(yamlEscaped("\(meeting.obsidianFileName) - Notes"))
        meeting_title: \(yamlEscaped(meeting.title))
        meeting_date: \(yamlEscaped(isoTimestamp(meeting.date)))
        casablanca_type: "raw-notes"
        summary_note: \(yamlEscaped(summaryLink))
        ---

        # Raw Notes

        ## Meeting

        - Scheduled: \(meetingDisplayDate(meeting))
        \(participantsLine(for: meeting))
        \(recordingLine(for: meeting))
        - Summary note: \(summaryLink)

        ## Freeform Notes

        \(renderedFreeformNotes)\(timestampedNotesSection)
        """
    }

    private static func participantsLine(for meeting: Meeting) -> String {
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !participants.isEmpty else { return "- Participants: Not captured." }
        return "- Participants: \(participants.joined(separator: ", "))"
    }

    private static func recordingLine(for meeting: Meeting) -> String {
        guard let duration = meeting.recordingDuration else { return "- Recording: Not recorded." }
        return "- Recording: \(formattedDuration(duration))"
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    private static func meetingDisplayDate(_ meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: meeting.date)
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func yamlEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
```

- [ ] **Step 3: Trim `ExportService.swift` to a delegating shell (Obsidian only for now — destination routing comes in Task 10)**

Replace the body of `Casablanca/Services/ExportService.swift` with:

```swift
import Foundation

enum ExportError: LocalizedError {
    case missingVaultPath

    var errorDescription: String? {
        switch self {
        case .missingVaultPath:
            return "Set your Obsidian vault path in Settings before exporting."
        }
    }
}

struct ExportResult {
    let summaryURL: URL?
    let notesURL: URL

    var exportedURLs: [URL] {
        [summaryURL, notesURL].compactMap { $0 }
    }
}

enum ExportService {
    static func exportAutomaticallyIfEnabled(_ meeting: Meeting) {
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.autoExportEnabled),
              hasExportableContent(meeting)
        else { return }

        do {
            _ = try exportCompletedMeeting(meeting)
        } catch {
            print("Automatic export skipped:", error.localizedDescription)
        }
    }

    static func exportCompletedMeeting(_ meeting: Meeting) throws -> ExportResult {
        try ObsidianMeetingExporter.exportCompletedMeeting(meeting)
    }

    static func exportRawNotes(_ meeting: Meeting) throws -> ExportResult {
        try ObsidianMeetingExporter.exportRawNotes(meeting)
    }

    static func hasExportableContent(_ meeting: Meeting) -> Bool {
        meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !meeting.timestampedNotes.isEmpty
    }
}
```

Note: `hasExportableContent` is now internal (no `private`) so call sites in destination-aware routing can use it in Task 10.

Note: this step also flips the auto-export pref key from `autoExportNotesToObsidian` to `autoExportEnabled`. Once Task 11 (Settings UI) writes the new key, no behavior change is observable. Existing users will be migrated by `AppPreferences.migrateLegacyAutoExportKeyIfNeeded` at app startup (wired in Task 14).

- [ ] **Step 4: Run existing ExportService tests to verify they still pass**

Same command as Step 1. Expected: identical pass count to baseline.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/ObsidianMeetingExporter.swift Casablanca/Services/ExportService.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "refactor(export): extract ObsidianMeetingExporter from ExportService"
```

---

## Task 10: Route `ExportService` through the selected destination

**Files:**
- Modify: `Casablanca/Services/ExportService.swift`
- Create: `CasablancaTests/ExportServiceRoutingTests.swift`

The async surface needed for Apple Notes export means `ExportService` gains async overloads. Existing sync entry points keep behaving exactly as today (Obsidian only), so callers that haven't been updated still compile.

- [ ] **Step 1: Write failing routing tests**

Create `CasablancaTests/ExportServiceRoutingTests.swift`:

```swift
import XCTest
@testable import Casablanca

@MainActor
final class ExportServiceRoutingTests: XCTestCase {
    private func makeDefaults(suite: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testRoutesToAppleNotesWhenDestinationSelected() async throws {
        let defaults = makeDefaults()
        defaults.set(ExportDestination.appleNotes.rawValue, forKey: AppPreferenceKey.exportDestination)
        let scripting = InMemoryAppleNotesScripting()
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Notes"
        meeting.summary = "Summary"

        let result = try await ExportService.exportCompletedMeeting(
            meeting,
            defaults: defaults,
            appleNotesScripting: scripting
        )

        switch result {
        case .appleNotes(let summaryId, let notesId):
            XCTAssertNotNil(summaryId)
            XCTAssertFalse(notesId.isEmpty)
            let notes = await scripting.notes
            XCTAssertEqual(notes.count, 2)
        case .obsidian:
            XCTFail("Expected appleNotes route")
        }
    }

    func testRoutesToObsidianByDefault() async throws {
        let defaults = makeDefaults()
        let vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Notes"
        meeting.summary = "Summary"

        let result = try await ExportService.exportCompletedMeeting(
            meeting,
            defaults: defaults,
            appleNotesScripting: InMemoryAppleNotesScripting()
        )

        switch result {
        case .obsidian(let export):
            XCTAssertNotNil(export.summaryURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: export.notesURL.path))
        case .appleNotes:
            XCTFail("Expected obsidian route")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ExportServiceRoutingTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: Compile failure ("No exact matches in call to static method 'exportCompletedMeeting'").

- [ ] **Step 3: Extend `ExportService` with destination-aware async entry points**

In `Casablanca/Services/ExportService.swift`, add at the bottom of the `ExportService` enum (keeping all existing methods):

```swift
    enum DestinationResult {
        case obsidian(ExportResult)
        case appleNotes(summaryNoteId: String?, rawNotesNoteId: String)

        var destinationDisplayName: String {
            switch self {
            case .obsidian: return "Obsidian"
            case .appleNotes: return "Apple Notes"
            }
        }
    }

    static func exportCompletedMeeting(
        _ meeting: Meeting,
        defaults: UserDefaults = .standard,
        appleNotesScripting: AppleNotesScripting? = nil
    ) async throws -> DestinationResult {
        switch AppPreferences.exportDestination(in: defaults) {
        case .obsidian:
            return .obsidian(try ObsidianMeetingExporter.exportCompletedMeeting(meeting))
        case .appleNotes:
            let scripting = appleNotesScripting ?? NSAppleScriptAppleNotesScripting()
            let exporter = AppleNotesMeetingExporter(scripting: scripting)
            let result = try await exporter.export(meeting)
            return .appleNotes(summaryNoteId: result.summaryNoteId, rawNotesNoteId: result.rawNotesNoteId)
        }
    }

    static func exportRawNotes(
        _ meeting: Meeting,
        defaults: UserDefaults = .standard,
        appleNotesScripting: AppleNotesScripting? = nil
    ) async throws -> DestinationResult {
        switch AppPreferences.exportDestination(in: defaults) {
        case .obsidian:
            return .obsidian(try ObsidianMeetingExporter.exportRawNotes(meeting))
        case .appleNotes:
            let scripting = appleNotesScripting ?? NSAppleScriptAppleNotesScripting()
            let exporter = AppleNotesMeetingExporter(scripting: scripting)
            let result = try await exporter.exportRawNotesOnly(meeting)
            return .appleNotes(summaryNoteId: nil, rawNotesNoteId: result.rawNotesNoteId)
        }
    }

    static func exportAutomaticallyIfEnabled(
        _ meeting: Meeting,
        defaults: UserDefaults = .standard,
        appleNotesScripting: AppleNotesScripting? = nil
    ) async {
        guard defaults.bool(forKey: AppPreferenceKey.autoExportEnabled),
              hasExportableContent(meeting)
        else { return }
        do {
            _ = try await exportCompletedMeeting(meeting, defaults: defaults, appleNotesScripting: appleNotesScripting)
        } catch {
            print("Automatic export skipped:", error.localizedDescription)
        }
    }
```

The legacy sync `exportCompletedMeeting(_:)`, `exportRawNotes(_:)`, and `exportAutomaticallyIfEnabled(_:)` from Task 9 must remain so existing call sites still build. They unconditionally use the Obsidian path. Task 12+ will migrate call sites onto the async destination-aware overloads.

- [ ] **Step 4: Run all export tests**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ExportServiceTests \
  -only-testing:CasablancaTests/ExportServiceRoutingTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: existing `ExportServiceTests` still pass, both routing tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/ExportService.swift CasablancaTests/ExportServiceRoutingTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(export): route ExportService through selected destination"
```

---

## Task 11: Gate `MeetingPrepService` on `PrepTodoStorage`

**Files:**
- Modify: `Casablanca/Services/MeetingPrepService.swift`
- Modify: `CasablancaTests/MeetingPrepServiceTests.swift` (add new tests; keep existing)

In Local mode, `prepURL`, `loadPrepMarkdown`, and `hasPrep` all return nil/false regardless of vault state.

- [ ] **Step 1: Write failing tests**

Append to `CasablancaTests/MeetingPrepServiceTests.swift` (create the file if it doesn't exist — it does):

```swift
    func testPrepURLReturnsNilInLocalMode() {
        let defaults = UserDefaults(suiteName: "prep-local-\(UUID().uuidString)")!
        defaults.set("/tmp/vault", forKey: AppPreferenceKey.obsidianVaultPath)
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let meeting = Meeting(title: "Sync", date: .now)
        XCTAssertNil(MeetingPrepService.prepURL(for: meeting, userDefaults: defaults))
    }

    func testLoadPrepMarkdownReturnsNilInLocalMode() {
        let defaults = UserDefaults(suiteName: "prep-local-\(UUID().uuidString)")!
        defaults.set("/tmp/vault", forKey: AppPreferenceKey.obsidianVaultPath)
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let meeting = Meeting(title: "Sync", date: .now)
        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    func testHasPrepReturnsFalseInLocalMode() {
        let defaults = UserDefaults(suiteName: "prep-local-\(UUID().uuidString)")!
        defaults.set("/tmp/vault", forKey: AppPreferenceKey.obsidianVaultPath)
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let meeting = Meeting(title: "Sync", date: .now)
        XCTAssertFalse(MeetingPrepService.hasPrep(for: meeting, userDefaults: defaults))
    }
```

(Place these inside the existing test class.)

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/MeetingPrepServiceTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: the new three tests fail (URL not nil, markdown not nil, has prep returns true or compile-failure if helpers don't exist yet).

- [ ] **Step 3: Add gating to `MeetingPrepService`**

Replace `Casablanca/Services/MeetingPrepService.swift` with:

```swift
import Foundation

enum MeetingPrepService {
    static func prepURL(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return nil }
        return ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults)?.prepURL
    }

    static func loadPrepMarkdown(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return nil }
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) else {
            return nil
        }

        for prepURL in files.prepCandidates {
            guard let markdown = try? String(contentsOf: prepURL, encoding: .utf8) else { continue }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return markdown }
        }
        return nil
    }

    static func hasPrep(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return false }
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) else {
            return false
        }
        return files.prepCandidates.contains { fileManager.fileExists(atPath: $0.path) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all `MeetingPrepServiceTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/MeetingPrepService.swift CasablancaTests/MeetingPrepServiceTests.swift
git commit -m "feat(prep): gate MeetingPrepService on PrepTodoStorage preference"
```

---

## Task 12: Gate `ObsidianTodoSyncService` on `PrepTodoStorage` and add Local-mode behavior

**Files:**
- Modify: `Casablanca/Services/ObsidianTodoSyncService.swift`
- Modify: `CasablancaTests/ObsidianTodoSyncServiceTests.swift` (append tests)

In Local mode, all read/write methods do not touch the filesystem. `createGenericTodo`, `createMeetingTodo`, `setCompleted`, `deleteTodo`, `refreshTodos`, `refreshAllTodos` must operate on SwiftData only.

- [ ] **Step 1: Write failing tests**

Append to `CasablancaTests/ObsidianTodoSyncServiceTests.swift`:

```swift
    @MainActor
    func testCreateGenericTodoInLocalModePersistsSwiftDataOnly() throws {
        let defaults = UserDefaults(suiteName: "todos-local-\(UUID().uuidString)")!
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        defaults.set("/tmp/no-such-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let context = try makeInMemoryModelContext()

        try ObsidianTodoSyncService.createGenericTodo(
            text: "Buy milk",
            in: context,
            userDefaults: defaults
        )

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 1)
        XCTAssertNil(todos[0].sourceFilePath)
        XCTAssertNil(todos[0].meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/no-such-vault"))
    }

    @MainActor
    func testCreateMeetingTodoInLocalModePersistsSwiftDataOnly() throws {
        let defaults = UserDefaults(suiteName: "todos-local-\(UUID().uuidString)")!
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        defaults.set("/tmp/no-such-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Sync", date: .now)
        context.insert(meeting)

        try ObsidianTodoSyncService.createMeetingTodo(
            text: "Send recap",
            meeting: meeting,
            in: context,
            userDefaults: defaults
        )

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 1)
        XCTAssertNil(todos[0].sourceFilePath)
        XCTAssertEqual(todos[0].meeting?.id, meeting.id)
    }

    @MainActor
    func testSetCompletedInLocalModeSkipsFilesystem() throws {
        let defaults = UserDefaults(suiteName: "todos-local-\(UUID().uuidString)")!
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let context = try makeInMemoryModelContext()
        // Pre-existing row with a stale source path that no longer corresponds to anything on disk.
        let todo = TodoItem(text: "Old", isCompleted: false, sourceFilePath: "/tmp/no-such-vault/tasks/Casablanca Todos.md")
        context.insert(todo)

        try ObsidianTodoSyncService.setCompleted(true, for: todo, in: context, userDefaults: defaults)

        XCTAssertTrue(todo.isCompleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/no-such-vault/tasks/Casablanca Todos.md"))
    }

    @MainActor
    func testDeleteTodoInLocalModeSkipsFilesystem() throws {
        let defaults = UserDefaults(suiteName: "todos-local-\(UUID().uuidString)")!
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let context = try makeInMemoryModelContext()
        let todo = TodoItem(text: "Old", sourceFilePath: "/tmp/no-such-vault/Old.md")
        context.insert(todo)

        try ObsidianTodoSyncService.deleteTodo(todo, in: context, userDefaults: defaults)

        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).count, 0)
    }

    @MainActor
    func testRefreshAllTodosInLocalModeIsNoop() throws {
        let defaults = UserDefaults(suiteName: "todos-local-\(UUID().uuidString)")!
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        defaults.set("/tmp/no-such-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let context = try makeInMemoryModelContext()

        XCTAssertNoThrow(try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults))
    }
```

You will need a `makeInMemoryModelContext()` helper. If one doesn't exist in this test class already, add it as a private method:

```swift
    private func makeInMemoryModelContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, TodoItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }
```

And ensure `import SwiftData` is present in the test file.

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ObsidianTodoSyncServiceTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: new tests fail (existing tests still pass).

- [ ] **Step 3: Add Local-mode gating to `ObsidianTodoSyncService`**

In `Casablanca/Services/ObsidianTodoSyncService.swift`, add an early-return at the top of each public static method when `AppPreferences.prepTodoStorage(in: userDefaults) == .local`. Concretely:

**`refreshAllTodos`** — replace the body's first lines:

```swift
    static func refreshAllTodos(
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return }
        try bootstrapLegacyGenericTodos(in: modelContext, userDefaults: userDefaults, fileManager: fileManager)
        // ...rest unchanged
```

**`refreshTodos(for:)`** — add the same guard at the top.

**`createGenericTodo`** — replace the body so that in Local mode it bypasses the markdown file and writes SwiftData only:

```swift
    static func createGenericTodo(
        text: String,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            let todo = TodoItem(text: trimmed, isCompleted: false, sourceFilePath: nil, meeting: nil)
            modelContext.insert(todo)
            try modelContext.save()
            return
        }

        // Existing Obsidian flow follows here:
        let genericURL = try genericTodosURL(userDefaults: userDefaults)
        // ...unchanged
```

**`createMeetingTodo`** — analogous:

```swift
    static func createMeetingTodo(
        text: String,
        meeting: Meeting,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            let todo = TodoItem(text: trimmed, isCompleted: false, sourceFilePath: nil, meeting: meeting)
            modelContext.insert(todo)
            try modelContext.save()
            return
        }

        // Existing Obsidian flow follows here:
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults, fileManager: fileManager) else {
            return
        }
        // ...unchanged
```

**`setCompleted`** — short-circuit when in Local mode:

```swift
    static func setCompleted(
        _ isCompleted: Bool,
        for todo: TodoItem,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            todo.isCompleted = isCompleted
            try modelContext.save()
            return
        }
        guard let sourceFilePath = todo.sourceFilePath else { return }
        // Existing filesystem flow unchanged below.
```

**`deleteTodo`** — analogous:

```swift
    static func deleteTodo(
        _ todo: TodoItem,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            modelContext.delete(todo)
            try modelContext.save()
            return
        }
        guard let sourceFilePath = todo.sourceFilePath else {
            // ...existing path
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all `ObsidianTodoSyncServiceTests` pass, including the new Local-mode tests.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/ObsidianTodoSyncService.swift CasablancaTests/ObsidianTodoSyncServiceTests.swift
git commit -m "feat(todos): gate ObsidianTodoSyncService on PrepTodoStorage and add Local mode"
```

---

## Task 13: Wire the legacy-pref migration into app launch

**Files:**
- Modify: `Casablanca/CasablancaApp.swift`

- [ ] **Step 1: Read the current entry point**

Open `Casablanca/CasablancaApp.swift` in your editor (or run `cat Casablanca/CasablancaApp.swift`) and find the `App` struct definition. Determine whether an `init()` already exists.

- [ ] **Step 2: Add the migration call**

Inside `CasablancaApp.swift`, at the top of the `App` struct's `init()`, add:

```swift
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded()
```

If no `init()` exists, add one:

```swift
    init() {
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded()
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/CasablancaApp.swift
git commit -m "feat(prefs): seed autoExportEnabled from legacy key at app launch"
```

---

## Task 14: Update view call sites to use destination-aware export and storage-aware todos

**Files:**
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift`
- Modify: `Casablanca/Views/TranscriptionView.swift`
- Modify: `Casablanca/Views/TodosView.swift`

Each view that currently calls `ExportService.exportCompletedMeeting(_)`, `ExportService.exportRawNotes(_)`, or `ExportService.exportAutomaticallyIfEnabled(_)` must move to the async destination-aware overloads and present destination-appropriate success/failure copy. View call sites that call `ObsidianTodoSyncService` already pick up Local-mode behavior automatically (Task 12 handles gating internally).

- [ ] **Step 1: Find every call site**

Run:

```bash
grep -rn "ExportService\." Casablanca/Views/
```

Enumerate each call to `exportCompletedMeeting`, `exportRawNotes`, and `exportAutomaticallyIfEnabled`.

For each match:

1. Convert the call into `try await ExportService.exportCompletedMeeting(meeting)` (or the raw-notes variant) inside a `Task { @MainActor in ... }`.
2. Switch on the `DestinationResult` returned to produce the success message:
   - `.obsidian(let result)` — use existing wording referencing the saved file URLs in `result.exportedURLs`.
   - `.appleNotes` — show "Saved to Apple Notes folder Casablanca."
3. Map thrown errors to user-facing copy via `error.localizedDescription` (this already works for `AppleNotesExportError` and `ExportError`).

In `TranscriptionView.swift`, change any "Will export to Obsidian" / "Auto-exported to Obsidian" copy to be destination-aware:

```swift
let destinationName: String = {
    switch AppPreferences.exportDestination() {
    case .obsidian: return "Obsidian"
    case .appleNotes: return "Apple Notes"
    }
}()
```

Use `destinationName` in user-visible strings instead of the hard-coded "Obsidian".

In `TodosView.swift`, hide any "Open in Obsidian" affordance when `AppPreferences.prepTodoStorage() == .local` (similarly in other views — typically `MeetingPrepService.prepURL(...)` already returns nil, so the affordance disappears, but verify in each call site).

- [ ] **Step 2: Build and run the existing UI/workflow test suite**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: full test suite passes (no UI tests should regress; the existing `MeetingStartFlowTests` and similar should still pass since Local mode defaults are unchanged).

- [ ] **Step 3: Manually verify end-to-end Obsidian flow has not regressed**

Open Casablanca, leave both prefs at defaults, record/import a meeting, manually export. Verify:
- Markdown files appear in the configured vault under `meeting notes/`.
- Auto-export still triggers when `autoExportEnabled` is on.
- Open-in-Obsidian affordances still work.

This is a manual smoke; record findings in the commit message if anything regressed and fix before committing.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Views/NotesEditorView.swift Casablanca/Views/RecordedMeetingView.swift Casablanca/Views/TranscriptionView.swift Casablanca/Views/TodosView.swift
git commit -m "feat(views): switch export call sites to destination-aware async API"
```

---

## Task 15: Settings UI — destination & storage pickers, helper text, mode-transition refresh

**Files:**
- Modify: `Casablanca/Views/SettingsView.swift`

- [ ] **Step 1: Add the two pickers**

Inside `SettingsView`, add a new section (or extend the existing export section) with:

```swift
@AppStorage(AppPreferenceKey.exportDestination) private var exportDestinationRaw: String = ExportDestination.obsidian.rawValue
@AppStorage(AppPreferenceKey.prepTodoStorage) private var prepTodoStorageRaw: String = PrepTodoStorage.obsidian.rawValue

private var exportDestination: ExportDestination {
    get { ExportDestination(rawValue: exportDestinationRaw) ?? .obsidian }
    set { exportDestinationRaw = newValue.rawValue }
}
private var prepTodoStorage: PrepTodoStorage {
    get { PrepTodoStorage(rawValue: prepTodoStorageRaw) ?? .obsidian }
    set { prepTodoStorageRaw = newValue.rawValue }
}
```

And in the section body:

```swift
Picker("Export destination", selection: $exportDestinationRaw) {
    Text("Obsidian").tag(ExportDestination.obsidian.rawValue)
    Text("Apple Notes").tag(ExportDestination.appleNotes.rawValue)
}

Text(exportDestination == .obsidian
    ? "Meeting notes are saved as Markdown to your Obsidian vault."
    : "Meeting notes are saved to the Casablanca folder in Apple Notes. The first export will ask for permission to control Notes.")
    .font(.callout)
    .foregroundStyle(.secondary)

Picker("Prep & todo storage", selection: $prepTodoStorageRaw) {
    Text("Obsidian").tag(PrepTodoStorage.obsidian.rawValue)
    Text("Local (Casablanca only)").tag(PrepTodoStorage.local.rawValue)
}

Text(prepTodoStorage == .obsidian
    ? "Prep notes are read from your Obsidian vault and todos sync to and from your vault."
    : "Prep notes are hidden. Todos are stored only inside Casablanca.")
    .font(.callout)
    .foregroundStyle(.secondary)
```

Update existing helper copy under the vault path field to read:

> "Your Obsidian vault path is required when Obsidian is selected for export or for prep & todo storage."

- [ ] **Step 2: Trigger an Obsidian refresh when storage flips Local → Obsidian**

Use `onChange` on `prepTodoStorageRaw`:

```swift
.onChange(of: prepTodoStorageRaw) { _, newValue in
    if newValue == PrepTodoStorage.obsidian.rawValue {
        Task { @MainActor in
            do {
                try ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
            } catch {
                // Best-effort refresh — surface non-blocking error in console only.
                print("Storage transition refresh failed:", error.localizedDescription)
            }
        }
    }
}
```

`modelContext` must be available via `@Environment(\.modelContext)`. If it's not yet injected into `SettingsView`, add `@Environment(\.modelContext) private var modelContext` at the top of the view.

- [ ] **Step 3: Build the app and run the full suite**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: full suite passes.

- [ ] **Step 4: Manual UI verification**

Open the app, go to Settings. Verify:
- Both pickers render and persist their selections across relaunches.
- Helper copy updates immediately when the selection changes.
- Selecting Apple Notes does not break the rest of the Settings sheet.
- Switching `Prep & todo storage` from Local back to Obsidian triggers a refresh (todos from the vault re-appear).

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Views/SettingsView.swift
git commit -m "feat(settings): add export destination and prep/todo storage pickers"
```

---

## Task 16: End-to-end smoke and final verification

**Files:** none modified.

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: all tests pass.

- [ ] **Step 2: Manual end-to-end smoke test for Apple Notes**

Build a debug app bundle:

```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Launch the built `.app`. Steps:

1. Settings → Export destination → Apple Notes.
2. Pick a meeting with summary + notes content.
3. Manually export.
4. macOS will prompt for Automation access to Notes the first time — accept.
5. Verify: Apple Notes shows a `Casablanca` folder with two notes (`YYYY-MM-DD Title` and `YYYY-MM-DD Title - Notes`). The summary note ends with the visible footer marker `Casablanca id: <UUID> / summary`. The raw-notes note ends with `... / notes`.
6. Edit the meeting in Casablanca (change the summary), re-export. Verify: same two notes are updated, **no duplicates** are created.
7. Delete the `Casablanca` folder in Notes. Re-export. Verify: folder is recreated and notes reappear.
8. Settings → Export destination → Obsidian. Verify: manual export writes markdown to the vault as before.

If any step fails, file a fix-up task and resolve before completion.

- [ ] **Step 3: Update README**

In `README.md`, under "What `v0.X.0` includes", add a bullet:

> Apple Notes export option, plus a Local-only mode for prep notes and todos.

- [ ] **Step 4: Final commit and push**

```bash
git add README.md
git commit -m "docs: announce Apple Notes export and local prep/todos in README"
```

Optionally open a PR:

```bash
gh pr create --base master --title "Apple Notes export and local prep/todos" --body "$(cat <<'EOF'
## Summary
- Adds Export destination preference (Obsidian / Apple Notes)
- Adds Prep & todo storage preference (Obsidian / Local)
- Obsidian-mode behavior is unchanged

## Test plan
- [ ] Full XCTest suite passes
- [ ] Manual end-to-end smoke for Apple Notes export (create, update, folder recreate)
- [ ] Manual end-to-end smoke for Local prep/todo storage
- [ ] Obsidian regression smoke

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Plan Notes

- Subagent execution should treat each task as a single PR-worthy commit.
- Tasks 1–10 are pure backend and have no UI surface; failure isolates well.
- Tasks 11–12 are storage gating; failures may cascade into Tasks 14 and 15.
- Task 8 (production AppleScript) cannot be fully unit-tested; rely on the manual smoke in Task 16 and the fake-driven exporter tests in Task 6 for confidence.
- If Task 4 reveals that Notes drops trailing `<p>` markers in practice (smoke-test surprise), move the marker to a leading `<p>` and re-run Task 6 tests with the updated `AppleNotesBodyRenderer` and `findNote` marker string.
