# To-Dos & Meeting History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-meeting to-do system to Casablanca. Todos are auto-extracted from the Ollama summary, reviewed by the user in a sheet before saving, and displayed in a global To-Dos sidebar section. The sidebar gains a To-Dos item with badge count, and the existing Meetings view gets a To-Dos tab.

**Architecture:** The existing `Meeting` SwiftData model gains a `@Relationship(deleteRule: .cascade)` to a new `TodoItem` model. After summarization, `SummaryResponseParser` splits the Ollama response into summary + todo texts. A `TodoReviewSheet` lets the user edit/delete/add todos before persisting. The sidebar adds a "To-Dos" destination. A new `TodosView` shows all todos across meetings as a flat list with segmented filter (Open/Done/All).

**Tech Stack:** SwiftUI, SwiftData (already in use), Ollama (existing `SummarizationService`)

---

## File Map

| File | Action |
|------|--------|
| `Casablanca/Models/TodoItem.swift` | Create — SwiftData model |
| `Casablanca/Models/Meeting.swift` | Modify — add `todos` relationship |
| `Casablanca/Models/PendingTodoReview.swift` | Create — transient review state struct |
| `Casablanca/Services/SummaryResponseParser.swift` | Create — pure parser for structured Ollama response |
| `Casablanca/Services/SummarizationService.swift` | Modify — append structured format instruction to prompt, parse response |
| `Casablanca/Services/ExportService.swift` | Modify — include action items in Obsidian export |
| `Casablanca/Views/TodoReviewSheet.swift` | Create — post-summarization review UI |
| `Casablanca/Views/TodosView.swift` | Create — global flat todo list |
| `Casablanca/Views/SidebarView.swift` | Modify — add To-Dos destination with badge |
| `Casablanca/Views/ContentView.swift` | Modify — route `.todos` sidebar destination |
| `Casablanca/Views/RecordedMeetingView.swift` | Modify — add To-Dos tab in meeting detail, trigger review sheet |
| `Casablanca/ViewModels/MeetingListViewModel.swift` | Modify — add navigation helpers for todo → meeting |
| `Casablanca/CasablancaApp.swift` | Modify — register `TodoItem` in `ModelContainer` |
| `CasablancaTests/SummaryResponseParserTests.swift` | Create — unit tests for parser |

---

## Task 1: Create TodoItem SwiftData model

**Files:**
- Create: `Casablanca/Models/TodoItem.swift`
- Modify: `Casablanca/Models/Meeting.swift`
- Modify: `Casablanca/CasablancaApp.swift`

- [ ] **Step 1: Create TodoItem.swift**

```swift
// Casablanca/Models/TodoItem.swift
import Foundation
import SwiftData

@Model
final class TodoItem {
    var id: UUID
    var text: String
    var isCompleted: Bool
    var createdAt: Date
    var meeting: Meeting?

    init(text: String, meeting: Meeting? = nil) {
        self.id = UUID()
        self.text = text
        self.isCompleted = false
        self.createdAt = Date()
        self.meeting = meeting
    }
}
```

- [ ] **Step 2: Add todos relationship to Meeting**

In `Casablanca/Models/Meeting.swift`, add a property after the existing `createdAt` property:

```swift
@Relationship(deleteRule: .cascade, inverse: \TodoItem.meeting) var todos: [TodoItem] = []
```

And in the `init(...)`, add `self.todos = []` at the end.

- [ ] **Step 3: Register TodoItem in ModelContainer**

In `Casablanca/CasablancaApp.swift`, change:

```swift
sharedModelContainer = try ModelContainer(for: Meeting.self)
```

to:

```swift
sharedModelContainer = try ModelContainer(for: Meeting.self, TodoItem.self)
```

- [ ] **Step 4: Verify build**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Models/TodoItem.swift Casablanca/Models/Meeting.swift Casablanca/CasablancaApp.swift
git commit -m "feat: add TodoItem SwiftData model with cascade relationship to Meeting"
```

---

## Task 2: Create SummaryResponseParser with tests

**Files:**
- Create: `Casablanca/Services/SummaryResponseParser.swift`
- Create: `CasablancaTests/SummaryResponseParserTests.swift`

- [ ] **Step 1: Create the test file with failing tests**

```swift
// CasablancaTests/SummaryResponseParserTests.swift
import XCTest
@testable import Casablanca

final class SummaryResponseParserTests: XCTestCase {

    func test_fullResponse_extractsSummaryAndTodos() {
        let raw = """
        # Summary

        The team agreed to ship by Friday.

        ## Decisions

        - Use SwiftUI for the new dashboard.

        ## Action Items

        - Send the build to QA
        - Update the changelog
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertTrue(result.summary.contains("The team agreed to ship by Friday."))
        XCTAssertEqual(result.todoTexts, ["Send the build to QA", "Update the changelog"])
    }

    func test_noActionItems_returnsEmptyTodos() {
        let raw = """
        # Summary

        Informational meeting, no actions.

        ## Action Items
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertTrue(result.summary.contains("Informational meeting, no actions."))
        XCTAssertTrue(result.todoTexts.isEmpty)
    }

    func test_malformedResponse_treatsEntireResponseAsSummary() {
        let raw = "The model just wrote prose with no structure at all."
        let result = SummaryResponseParser.parse(raw)
        XCTAssertEqual(result.summary, raw)
        XCTAssertTrue(result.todoTexts.isEmpty)
    }

    func test_actionItemsWithOwners_preservesFull() {
        let raw = """
        # Summary

        Quick sync.

        ## Action Items

        - @Alice: Draft the proposal by Thursday
        - @Bob: Review the API spec
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertEqual(result.todoTexts, [
            "@Alice: Draft the proposal by Thursday",
            "@Bob: Review the API spec"
        ])
    }

    func test_extraSectionsAfterActionItems_ignored() {
        let raw = """
        # Summary

        All good.

        ## Action Items

        - Ship it

        ## Follow-ups

        - Check metrics next week
        """
        let result = SummaryResponseParser.parse(raw)
        XCTAssertEqual(result.todoTexts, ["Ship it"])
    }
}
```

- [ ] **Step 2: Run tests — expect build failure**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild test -scheme Casablanca -only-testing CasablancaTests/SummaryResponseParserTests 2>&1 | tail -10
```
Expected: compile error — `SummaryResponseParser` not found.

- [ ] **Step 3: Create SummaryResponseParser.swift**

```swift
// Casablanca/Services/SummaryResponseParser.swift
import Foundation

enum SummaryResponseParser {
    struct ParsedResponse {
        let summary: String
        let todoTexts: [String]
    }

    static func parse(_ response: String) -> ParsedResponse {
        let actionItemsMarker = "\n## Action Items"

        guard let markerRange = response.range(of: actionItemsMarker) else {
            return ParsedResponse(
                summary: response.trimmingCharacters(in: .whitespacesAndNewlines),
                todoTexts: []
            )
        }

        let summary = String(response[response.startIndex..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let afterMarker = String(response[markerRange.upperBound...])

        // Action items end at the next ## section header or end of string
        let actionSection: String
        if let nextSectionRange = afterMarker.range(of: "\n## ", range: afterMarker.index(afterMarker.startIndex, offsetBy: 1)..<afterMarker.endIndex) {
            actionSection = String(afterMarker[afterMarker.startIndex..<nextSectionRange.lowerBound])
        } else {
            actionSection = afterMarker
        }

        let todoTexts = actionSection
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return nil }
                let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }

        return ParsedResponse(summary: summary, todoTexts: todoTexts)
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild test -scheme Casablanca -only-testing CasablancaTests/SummaryResponseParserTests 2>&1 | tail -15
```
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/SummaryResponseParser.swift CasablancaTests/SummaryResponseParserTests.swift
git commit -m "feat: add SummaryResponseParser with tests for extracting todos from Ollama response"
```

---

## Task 3: Create PendingTodoReview transient model

**Files:**
- Create: `Casablanca/Models/PendingTodoReview.swift`

- [ ] **Step 1: Create PendingTodoReview.swift**

```swift
// Casablanca/Models/PendingTodoReview.swift
import Foundation

struct PendingTodoReview: Identifiable {
    let id = UUID()
    let meetingID: UUID
    let summary: String
    var todoTexts: [String]
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/Models/PendingTodoReview.swift
git commit -m "feat: add PendingTodoReview transient struct for review sheet state"
```

---

## Task 4: Update SummarizationService to return structured response

**Files:**
- Modify: `Casablanca/Services/SummarizationService.swift`

The `SummarizationService.summarize(meeting:)` method currently returns a plain `String`. We change it to return a `SummaryResponseParser.ParsedResponse` so the caller gets both summary and todoTexts.

- [ ] **Step 1: Update the prompt template**

In `SummarizationService.swift`, change `defaultPromptTemplate` to:

```swift
static let defaultPromptTemplate = """
You are a meeting assistant creating concise, high-signal meeting notes.

Use only the information provided below. If something is unclear or missing, say so briefly instead of guessing.

Return markdown with these sections:
# Summary
## Decisions
## Action Items
## Risks and Blockers
## Follow-ups

Keep action items concrete and include owners when they are stated.
Each action item MUST be a `- ` bullet under "## Action Items". If there are no action items, write "## Action Items" with nothing below it.

Meeting title: {{title}}
Scheduled time: {{scheduled_time}}

Transcript:
{{transcript}}

Timestamped notes:
{{timestamped_notes}}

Freeform notes:
{{freeform_notes}}
"""
```

- [ ] **Step 2: Change the return type of `summarize(meeting:)`**

Change the method signature from:

```swift
func summarize(meeting: Meeting) async throws -> String {
```

to:

```swift
func summarize(meeting: Meeting) async throws -> SummaryResponseParser.ParsedResponse {
```

At the end of the method, replace:

```swift
statusMessage = "Summary generated"
return summary
```

with:

```swift
statusMessage = "Summary generated"
return SummaryResponseParser.parse(summary)
```

- [ ] **Step 3: Verify build — expect failures in callers**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | grep "error:" | head -10
```
Expected: errors in `RecordedMeetingView.swift` where `summarize` return value is used as `String`. This is expected — we fix it in Task 7.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Services/SummarizationService.swift
git commit -m "feat: update SummarizationService to return parsed summary + todoTexts"
```

---

## Task 5: Update ExportService to include action items

**Files:**
- Modify: `Casablanca/Services/ExportService.swift`

- [ ] **Step 1: Add action items to summary markdown**

In `ExportService.swift`, update the `summaryMarkdown(for:notesFileName:)` method. After the `# Summary` section and before `## Meeting`, add a todo section. Change:

```swift
return """
---
title: \(yamlEscaped(meeting.obsidianFileName))
meeting_title: \(yamlEscaped(meeting.title))
meeting_date: \(yamlEscaped(isoTimestamp(meeting.date)))
casablanca_type: "meeting-summary"
raw_notes: \(yamlEscaped(notesLink))
---

# Summary

\(summary)

## Meeting
```

to:

```swift
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
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | grep "error:" | head -5
```
Expected: still errors from Task 4's caller change — ExportService itself should compile cleanly.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/Services/ExportService.swift
git commit -m "feat: include action items in Obsidian summary export"
```

---

## Task 6: Create TodoReviewSheet

**Files:**
- Create: `Casablanca/Views/TodoReviewSheet.swift`

- [ ] **Step 1: Create TodoReviewSheet.swift**

```swift
// Casablanca/Views/TodoReviewSheet.swift
import SwiftUI

struct TodoReviewSheet: View {
    let meetingTitle: String
    let summary: String
    @Binding var todoTexts: [String]
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var newItemText = ""
    @FocusState private var focusedItemIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: CasaSpace.lg) {
                    summaryPreview
                    todoList
                }
                .padding(CasaSpace.xl)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 400, idealHeight: 500)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(meetingTitle)
                    .font(.headline)
                Text("Review action items before saving")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            Button("Discard All", role: .destructive, action: onDiscard)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentDanger)
        }
        .padding(CasaSpace.lg)
    }

    private var summaryPreview: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Summary")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)

            Text(summary)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CasaSpace.md)
                .background(Color.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.md))
        }
    }

    private var todoList: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Action Items (\(todoTexts.count))")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)

            ForEach(todoTexts.indices, id: \.self) { index in
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.textTertiary)
                        .font(.body)

                    TextField("Action item", text: $todoTexts[index])
                        .textFieldStyle(.plain)
                        .focused($focusedItemIndex, equals: index)

                    Button {
                        todoTexts.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.textTertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(CasaSpace.sm)
                .background(Color.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
            }

            HStack(spacing: CasaSpace.sm) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.accentPrimary)

                TextField("Add action item...", text: $newItemText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let trimmed = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        todoTexts.append(trimmed)
                        newItemText = ""
                    }
            }
            .padding(CasaSpace.sm)
            .background(Color.backgroundSecondary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(action: onSave) {
                Text("Save Meeting & To-Dos")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(CasaSpace.lg)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | grep "error:" | head -5
```
Expected: still errors from Task 4 — TodoReviewSheet itself should compile.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/Views/TodoReviewSheet.swift
git commit -m "feat: add TodoReviewSheet for post-summarization action item review"
```

---

## Task 7: Wire TodoReviewSheet into RecordedMeetingView

**Files:**
- Modify: `Casablanca/Views/RecordedMeetingView.swift`

This task fixes the build error from Task 4 (summarize now returns a `ParsedResponse`) and adds the review sheet + todos tab.

- [ ] **Step 1: Add state for pending review**

At the top of `RecordedMeetingView`, add these `@State` properties:

```swift
@State private var pendingReview: PendingTodoReview?
@State private var pendingTodoTexts: [String] = []
```

- [ ] **Step 2: Update the summarization call**

Find the code that calls `summarizationService.summarize(meeting:)` and assigns the result to `meeting.summary`. It will look something like:

```swift
let summary = try await summarizationService.summarize(meeting: meeting)
meeting.summary = summary
```

Change it to:

```swift
let parsed = try await summarizationService.summarize(meeting: meeting)
meeting.summary = parsed.summary
if !parsed.todoTexts.isEmpty {
    pendingTodoTexts = parsed.todoTexts
    pendingReview = PendingTodoReview(
        meetingID: meeting.id,
        summary: parsed.summary,
        todoTexts: parsed.todoTexts
    )
} else {
    try? modelContext.save()
    ExportService.exportAutomaticallyIfEnabled(meeting)
}
```

- [ ] **Step 3: Add the review sheet presentation**

Add a `.sheet(item:)` modifier to the outermost view in `body`:

```swift
.sheet(item: $pendingReview) { review in
    TodoReviewSheet(
        meetingTitle: meeting.title,
        summary: review.summary,
        todoTexts: $pendingTodoTexts,
        onSave: {
            saveTodos(texts: pendingTodoTexts)
            pendingReview = nil
        },
        onDiscard: {
            pendingReview = nil
            try? modelContext.save()
            ExportService.exportAutomaticallyIfEnabled(meeting)
        }
    )
    .interactiveDismissDisabled()
}
```

- [ ] **Step 4: Add the saveTodos helper**

Add a private method to `RecordedMeetingView`:

```swift
private func saveTodos(texts: [String]) {
    for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let todo = TodoItem(text: text, meeting: meeting)
        modelContext.insert(todo)
    }
    try? modelContext.save()
    ExportService.exportAutomaticallyIfEnabled(meeting)
}
```

- [ ] **Step 5: Add a To-Dos section to the meeting detail**

In the content layout of `RecordedMeetingView`, add a new card after the existing summary/transcript cards. This should display the meeting's todos with checkboxes:

```swift
// Add as a new card in the content layout
if !meeting.todos.isEmpty {
    VStack(alignment: .leading, spacing: CasaSpace.md) {
        Text("Action Items")
            .font(.headline)

        ForEach(meeting.todos.sorted(by: { $0.createdAt < $1.createdAt })) { todo in
            HStack(spacing: CasaSpace.sm) {
                Button {
                    todo.isCompleted.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(todo.isCompleted ? Color.accentSuccess : Color.textTertiary)
                }
                .buttonStyle(.borderless)

                Text(todo.text)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? Color.textTertiary : Color.textPrimary)
            }
        }
    }
    .modifier(CardStyle())
}
```

- [ ] **Step 6: Verify build**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Casablanca/Views/RecordedMeetingView.swift
git commit -m "feat: wire TodoReviewSheet into RecordedMeetingView with action items display"
```

---

## Task 8: Add To-Dos sidebar destination

**Files:**
- Modify: `Casablanca/Views/SidebarView.swift`
- Modify: `Casablanca/Views/ContentView.swift`

- [ ] **Step 1: Add `.todos` to SidebarDestination**

In `SidebarView.swift`, change the `SidebarDestination` enum:

```swift
enum SidebarDestination: Hashable {
    case dashboard
    case todos
    case meeting(UUID)
}
```

- [ ] **Step 2: Add To-Dos section to the sidebar**

In `SidebarView.body`, after the Dashboard section and before the Recent section, add:

```swift
Section {
    Label {
        Text("To-Dos")
    } icon: {
        Image(systemName: "checklist")
    }
    .tag(SidebarDestination.todos)
    .badge(openTodoCount)
}
```

- [ ] **Step 3: Add the openTodoCount query**

At the top of `SidebarView`, add:

```swift
@Query(filter: #Predicate<TodoItem> { !$0.isCompleted }) private var openTodos: [TodoItem]

private var openTodoCount: Int { openTodos.count }
```

- [ ] **Step 4: Route `.todos` in ContentView**

In `ContentView.swift`, update `detailView` to handle the new case. Change the `if let meeting = viewModel.selectedMeeting` block to first check the sidebar selection:

```swift
@ViewBuilder
private var detailView: some View {
    switch viewModel.sidebarSelection {
    case .todos:
        TodosView(viewModel: viewModel)
    case .meeting(let id):
        if let meeting = viewModel.selectedMeeting ?? viewModel.fetchMeeting(byID: id) {
            // ... existing switch on meeting.status ...
        } else {
            DashboardView(viewModel: viewModel)
        }
    case .dashboard, .none:
        DashboardView(viewModel: viewModel)
    }
}
```

- [ ] **Step 5: Handle `.todos` in MeetingListViewModel.sidebarSelection setter**

In `MeetingListViewModel.swift`, update the `sidebarSelection` setter's switch:

```swift
switch newValue {
case .dashboard, .todos:
    selectedMeeting = nil
case .meeting(let id):
    if selectedMeeting?.id != id {
        selectedMeeting = fetchMeeting(byID: id)
    }
}
```

- [ ] **Step 6: Verify build**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | tail -5
```
Expected: build error — `TodosView` not yet created. That's OK; we create it next.

- [ ] **Step 7: Commit**

```bash
git add Casablanca/Views/SidebarView.swift Casablanca/Views/ContentView.swift Casablanca/ViewModels/MeetingListViewModel.swift
git commit -m "feat: add To-Dos sidebar destination with open count badge"
```

---

## Task 9: Create TodosView

**Files:**
- Create: `Casablanca/Views/TodosView.swift`

- [ ] **Step 1: Create TodosView.swift**

```swift
// Casablanca/Views/TodosView.swift
import SwiftUI
import SwiftData

struct TodosView: View {
    @Bindable var viewModel: MeetingListViewModel
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var allTodos: [TodoItem]
    @Environment(\.modelContext) private var modelContext
    @State private var filter: TodoFilter = .open

    enum TodoFilter: String, CaseIterable {
        case open = "Open"
        case done = "Done"
        case all = "All"
    }

    var body: some View {
        VStack(spacing: 0) {
            if filteredTodos.isEmpty {
                emptyState
            } else {
                todoList
            }
        }
        .frame(maxWidth: CasaLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("To-Dos")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(TodoFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
        }
    }

    private var filteredTodos: [TodoItem] {
        switch filter {
        case .open:
            return allTodos.filter { !$0.isCompleted }
        case .done:
            return allTodos.filter { $0.isCompleted }
        case .all:
            return allTodos
        }
    }

    private var todoList: some View {
        List(filteredTodos) { todo in
            TodoRow(todo: todo) {
                if let meeting = todo.meeting {
                    viewModel.sidebarSelection = .meeting(meeting.id)
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .open: return "All Done"
        case .done: return "No Completed Items"
        case .all: return "No Action Items"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .open: return "checkmark.circle"
        case .done: return "circle"
        case .all: return "checklist"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .open: return "No open action items. Nice work."
        case .done: return "Completed action items will appear here."
        case .all: return "Action items from your meetings will appear here."
        }
    }
}

private struct TodoRow: View {
    @Bindable var todo: TodoItem
    let onNavigateToMeeting: () -> Void
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button(action: onNavigateToMeeting) {
            HStack(spacing: CasaSpace.sm) {
                Button {
                    todo.isCompleted.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(todo.isCompleted ? Color.accentSuccess : Color.textTertiary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)

                VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                    Text(todo.text)
                        .font(.body)
                        .strikethrough(todo.isCompleted)
                        .foregroundStyle(todo.isCompleted ? Color.textTertiary : Color.textPrimary)

                    if let meeting = todo.meeting {
                        Text("\(meeting.title) \u{00B7} \(formattedDate(meeting.date))")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild -scheme Casablanca -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run all tests**

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && xcodebuild test -scheme Casablanca 2>&1 | tail -15
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Views/TodosView.swift
git commit -m "feat: add TodosView with segmented filter and meeting navigation"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] TodoItem SwiftData model — Task 1
- [x] Meeting.todos relationship with cascade delete — Task 1
- [x] SummaryResponseParser (was OllamaResponseParser in original) — Task 2
- [x] PendingTodoReview transient struct — Task 3
- [x] Structured prompt update — Task 4
- [x] Obsidian export includes action items — Task 5
- [x] TodoReviewSheet with edit/delete/add — Task 6
- [x] RecordedMeetingView wires review sheet + shows todos — Task 7
- [x] Sidebar To-Dos destination with badge — Task 8
- [x] TodosView flat list with segmented filter — Task 9
- [x] Todo → meeting navigation — Task 9

**Placeholder scan:** No TBDs, TODOs, or "similar to Task N" references found.

**Type consistency:** `SummaryResponseParser.ParsedResponse`, `PendingTodoReview`, `TodoItem`, `SidebarDestination.todos` — all names consistent across tasks.
