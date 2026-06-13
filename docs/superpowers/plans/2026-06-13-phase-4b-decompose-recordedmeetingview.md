# Phase 4b: Decompose RecordedMeetingView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the ~941-line `Casablanca/Views/RecordedMeetingView.swift` post-recording detail view into focused subviews under `Casablanca/Views/MeetingDetail/`, dedupe the shared `presentExportAlert` NSAlert helper into `Casablanca/Views/Components/ExportAlertPresenter.swift`, with zero user-visible change.

**Architecture:** Pure structural decomposition. Each tab (summary / transcript / notes) and the inspector become standalone `View` structs that take the `Meeting` plus the specific bindings/closures/services they need; the parent keeps the tab `Picker`, `selectedTab`, `showInspector`, toolbar, `exportMeeting`, `save`, `triggerAutomaticSummaryIfNeeded`, the summary error alert, and `pipelineBanner` (Phase 5 territory). All view code moves **verbatim**, adapted only at the new struct boundary (env injection, closure params). The pure presentation logic (`ReviewPrimaryAction`, `primaryToolbarAction` as a free function, `TimeInterval.formattedRecordingDuration`) moves to a non-View file and gets unit tests.

**Tech Stack:** SwiftUI, SwiftData (`@Bindable Meeting`, `@Environment(\.modelContext)`), AppKit (`NSAlert`, `NSPasteboard`, `NSWorkspace`), XCTest. Build/test via `xcodebuild ... -destination 'platform=macOS'`.

---

## CRITICAL CONSTRAINTS (read before any task)

- **PURE STRUCTURAL** — behavior / layout / pixels IDENTICAL. No intentional user-visible change.
- The Notes tab's `ToastMarkdownEditor` (a `WKWebView`) **MUST keep its frame structure byte-identical**: the `VStack(spacing: 0) { ToastMarkdownEditor(...).frame(minHeight: 160).onChange(...) }.padding(CasaSpace.sm).background(Color.backgroundHover).clipShape(...)` block is load-bearing — WKWebView collapses to zero height without it. Do NOT wrap it in a ScrollView, do NOT restructure it. If it cannot be preserved verbatim, STOP and escalate BLOCKED.
- All existing tests stay green. Baseline is **≥386 tests Executed**.
- Known flake: `RecordingInterruptionCoordinatorTests.testResumeMarksCorrectRecordEvenIfNewInterruptionAppended` — if that's the ONLY failure, re-run once.

## Verified current line ranges (RecordedMeetingView.swift, 941 lines)

These drifted from the original prompt estimates; use these:

| Member | Lines |
|---|---|
| `DetailTab` enum (file-private, no external refs) | 21-27 |
| `body` | 29-70 |
| `readingColumn` | 74-101 |
| `infoBar` | 103-139 |
| `pipelineBanner` (STAYS in parent — Phase 5) | 141-158 |
| `summaryTab` | 162-224 |
| `summaryHero` | 226-257 |
| `parsedSection` | 259-275 |
| `bulletRow` | 277-289 |
| `actionItemsSection` | 291-329 |
| `transcriptTab` (+ terminology warning row) | 333-423 |
| `toolbarButton(for:isPrimary:)` (STAYS — toolbar) | 483-505 |
| `hasNotes` / `canSummarize` / `canExport` / `recordingURL` / `isSummarizingThisMeeting` / `shouldShowPipelineBanner` | 507-540 |
| `canReapplyTerminology` | 542-547 |
| `pipelineStatusText` (STAYS — feeds pipelineBanner) | 549-567 |
| `primaryToolbarAction` | 569-585 |
| `summaryErrorBinding` (STAYS) | 587-596 |
| `reapplyTerminology` / `restoreOriginalTranscript` | 598-616 |
| `exportMeeting` (STAYS) | 618-652 |
| `matchingTodo` / `isActionItemCompleted` / `toggleActionItem` | 654-689 |
| `inspector` + `recordingInspectorSection` + `participantsInspectorSection` + `exportInspectorSection` + `inspectorLabel` + `initials` | 693-799 |
| `secondaryActionsMenu` (STAYS — toolbar) | 801-844 |
| `save` / `debouncedSave` / `triggerAutomaticSummaryIfNeeded` (save & trigger STAY; debouncedSave moves) | 846-875 |
| `presentExportAlert` (DUPLICATED, byte-identical to NotesEditorView 474-491) | 877-894 |
| `renderedMarkdownSummary` | 896-916 |
| `ReviewPrimaryAction` enum (file-private) | 919-923 |
| `TimeInterval.formattedRecordingDuration` (file-private) | 925-940 |
| `notesTab` | 427-481 |

**Confirmed:** `presentExportAlert` in RecordedMeetingView (877-894) and NotesEditorView (474-491) are **byte-identical**. `ReviewPrimaryAction`, `TimeInterval.formattedRecordingDuration`, `DetailTab` have **no references outside RecordedMeetingView.swift**.

## File Structure (target)

- Create `Casablanca/Views/MeetingDetail/MeetingDetailPresentation.swift` — pure types: `ReviewPrimaryAction`, a `reviewPrimaryAction(...)` free function, `TimeInterval.formattedRecordingDuration`. Non-View, unit-testable.
- Create `Casablanca/Views/Components/ExportAlertPresenter.swift` — `presentExportAlert(title:message:exportedURLs:)` as a free function (shared by RecordedMeetingView + NotesEditorView).
- Create `Casablanca/Views/MeetingDetail/MeetingSummaryTab.swift` — `MeetingSummaryTab` View (summaryTab, summaryHero, parsedSection, bulletRow, actionItemsSection, renderedMarkdownSummary, matchingTodo/isActionItemCompleted/toggleActionItem).
- Create `Casablanca/Views/MeetingDetail/MeetingTranscriptTab.swift` — `MeetingTranscriptTab` View (transcriptTab, terminology warning row, reapplyTerminology, restoreOriginalTranscript, canReapplyTerminology).
- Create `Casablanca/Views/MeetingDetail/MeetingNotesTab.swift` — `MeetingNotesTab` View (notesTab, `isEditingNotes`, `saveTask`, `debouncedSave`). **ToastMarkdownEditor frame byte-identical.**
- Create `Casablanca/Views/MeetingDetail/MeetingDetailInspector.swift` — `MeetingDetailInspector` View (inspector, 3 sections, inspectorLabel, initials). Stateless.
- Modify `Casablanca/Views/RecordedMeetingView.swift` — shrink to ~280 lines; call the new subviews.
- Modify `Casablanca/Views/NotesEditorView.swift` — replace inline `presentExportAlert` with shared call.
- Create `CasablancaTests/MeetingDetailPresentationTests.swift` — unit tests for the pure logic.
- Modify `Casablanca.xcodeproj/project.pbxproj` — register new files + a new `MeetingDetail` group.

### Interface contracts (locked — used consistently across tasks)

```swift
// ExportAlertPresenter.swift — free function (AppKit, @MainActor by call context)
func presentExportAlert(title: String, message: String, exportedURLs: [URL])

// MeetingDetailPresentation.swift
enum ReviewPrimaryAction: Equatable { case transcribe, summarize, export }

/// Pure decision: which primary toolbar action to surface (nil = none).
func reviewPrimaryAction(
    hasTranscript: Bool,
    hasRecording: Bool,
    hasSummary: Bool,
    canSummarize: Bool,
    canExport: Bool
) -> ReviewPrimaryAction?

extension TimeInterval { var formattedRecordingDuration: String { ... } }

// MeetingSummaryTab.swift
struct MeetingSummaryTab: View {
    @Bindable var meeting: Meeting
    let isSummarizing: Bool          // = isSummarizingThisMeeting
    let statusMessage: String        // = summarizationService.statusMessage
    let canSummarize: Bool
    let onSummarize: () -> Void      // = summarizationService.summarizeInBackground(meeting:modelContext:)
    @Environment(\.modelContext) private var modelContext   // for todo sync
}

// MeetingTranscriptTab.swift
struct MeetingTranscriptTab: View {
    @Bindable var meeting: Meeting
    let terminologyService: TerminologyService
    let onTranscribe: () -> Void
    let onSave: () -> Void           // = parent save()
}

// MeetingNotesTab.swift
struct MeetingNotesTab: View {
    @Bindable var meeting: Meeting
    let onSave: () -> Void           // = parent save()
    @State private var isEditingNotes = false
    @State private var saveTask: Task<Void, Never>?
}

// MeetingDetailInspector.swift
struct MeetingDetailInspector: View {
    let meeting: Meeting             // read-only; not @Bindable
    let canExport: Bool
}
```

**State-ownership note:** `recordingURL` is a tiny pure derivation (`meeting.recordingFileURL` → file URL) needed by transcriptTab, inspector, and parent. To keep moves verbatim and avoid a shared-state question, **each subview that needs `recordingURL` gets its own private copy** of the computed property (it's 3 lines, derives purely from `meeting`, no state). The parent keeps its copy too. This is acceptable duplication of a pure derivation — do NOT try to hoist it into a shared model in this phase.

---

## Task 1: Extract pure presentation logic + unit tests (TDD)

**Files:**
- Create: `Casablanca/Views/MeetingDetail/MeetingDetailPresentation.swift`
- Create: `CasablancaTests/MeetingDetailPresentationTests.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift` (remove moved members, wire to free function)
- Modify: `Casablanca.xcodeproj/project.pbxproj`

The original `primaryToolbarAction` is a computed property reading instance state. We extract its decision into a pure free function so it's testable, then have the parent call it. The logic to preserve exactly (from lines 569-585):

```
if transcript empty/nil AND recordingURL != nil      -> .transcribe
else if summary empty/nil AND canSummarize           -> .summarize
else if canExport                                    -> .export
else                                                 -> nil
```

- [ ] **Step 1: Create `MeetingDetailPresentation.swift` with the pure logic**

```swift
import Foundation

enum ReviewPrimaryAction: Equatable {
    case transcribe
    case summarize
    case export
}

/// Pure decision for which primary action the review toolbar should surface.
/// Mirrors `RecordedMeetingView.primaryToolbarAction` ordering exactly.
func reviewPrimaryAction(
    hasTranscript: Bool,
    hasRecording: Bool,
    hasSummary: Bool,
    canSummarize: Bool,
    canExport: Bool
) -> ReviewPrimaryAction? {
    if !hasTranscript, hasRecording {
        return .transcribe
    }

    if !hasSummary, canSummarize {
        return .summarize
    }

    if canExport {
        return .export
    }

    return nil
}

extension TimeInterval {
    var formattedRecordingDuration: String {
        let totalSeconds = max(Int(rounded()), 0)
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

- [ ] **Step 2: Write the failing tests**

Create `CasablancaTests/MeetingDetailPresentationTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class MeetingDetailPresentationTests: XCTestCase {

    // MARK: - reviewPrimaryAction

    func testTranscribeWhenNoTranscriptButHasRecording() {
        let action = reviewPrimaryAction(
            hasTranscript: false, hasRecording: true,
            hasSummary: false, canSummarize: false, canExport: false
        )
        XCTAssertEqual(action, .transcribe)
    }

    func testNoTranscribeWhenNoRecordingEvenWithoutTranscript() {
        // No recording -> cannot transcribe; falls through.
        let action = reviewPrimaryAction(
            hasTranscript: false, hasRecording: false,
            hasSummary: false, canSummarize: false, canExport: false
        )
        XCTAssertNil(action)
    }

    func testSummarizeWhenTranscriptPresentNoSummaryAndCanSummarize() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: false, canSummarize: true, canExport: true
        )
        XCTAssertEqual(action, .summarize)
    }

    func testSummarizeNotChosenWhenCannotSummarize() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: false, canSummarize: false, canExport: true
        )
        XCTAssertEqual(action, .export)
    }

    func testExportWhenSummaryPresent() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: true, canSummarize: true, canExport: true
        )
        XCTAssertEqual(action, .export)
    }

    func testNilWhenNothingActionable() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: true, canSummarize: false, canExport: false
        )
        XCTAssertNil(action)
    }

    func testTranscribeTakesPriorityOverSummarize() {
        // No transcript + recording wins even if a summary path looks available.
        let action = reviewPrimaryAction(
            hasTranscript: false, hasRecording: true,
            hasSummary: false, canSummarize: true, canExport: true
        )
        XCTAssertEqual(action, .transcribe)
    }

    // MARK: - formattedRecordingDuration

    func testFormatSecondsOnly() {
        XCTAssertEqual(TimeInterval(45).formattedRecordingDuration, "45s")
    }

    func testFormatMinutesAndSeconds() {
        XCTAssertEqual(TimeInterval(125).formattedRecordingDuration, "2m 05s")
    }

    func testFormatHoursMinutesSeconds() {
        // 1h 02m 03s = 3723s
        XCTAssertEqual(TimeInterval(3723).formattedRecordingDuration, "1h 02m 03s")
    }

    func testFormatZero() {
        XCTAssertEqual(TimeInterval(0).formattedRecordingDuration, "0s")
    }

    func testFormatNegativeClampsToZero() {
        XCTAssertEqual(TimeInterval(-10).formattedRecordingDuration, "0s")
    }

    func testFormatRoundsToNearestSecond() {
        XCTAssertEqual(TimeInterval(59.6).formattedRecordingDuration, "1m 00s")
    }
}
```

- [ ] **Step 3: Register the two new files in `project.pbxproj`**

Use the Phase 4a fixed-ID convention. Apply these 5 edits (IDs `A10208`/`B10208` for the source file, `B10210` for the test source file ref + `A10210` build file; pick unused IDs — verify none of `A10208 A10210 B10208 B10210` already appear with `grep`).

1. **PBXBuildFile section** (after line 60, `A10207 ... BlockingProgressOverlay.swift in Sources`):
```
		A10208 /* MeetingDetailPresentation.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10208 /* MeetingDetailPresentation.swift */; };
		A10210 /* MeetingDetailPresentationTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10210 /* MeetingDetailPresentationTests.swift */; };
```

2. **PBXFileReference section** (after line 228, `B10207 ... BlockingProgressOverlay.swift`):
```
		B10208 /* MeetingDetailPresentation.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MeetingDetailPresentation.swift; sourceTree = "<group>"; };
		B10210 /* MeetingDetailPresentationTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MeetingDetailPresentationTests.swift; sourceTree = "<group>"; };
```

3. **Create the `MeetingDetail` group** — insert a new PBXGroup right after the `E10200 /* NotesEditor */` group block (after its closing `};` at line 603), using a fresh group ID `E10210`:
```
		E10210 /* MeetingDetail */ = {
			isa = PBXGroup;
			children = (
				B10208 /* MeetingDetailPresentation.swift */,
			);
			path = MeetingDetail;
			sourceTree = "<group>";
		};
```

4. **Add `MeetingDetail` group to the Views group children** — in the `Views` group (children list ends at line 537), insert after the `E10200 /* NotesEditor */,` line (line 523):
```
					E10210 /* MeetingDetail */,
```

5. **Add the test file to the CasablancaTests group children** — after line 642 (`CA1EAD0000000000000000F1 /* CalendarServiceTests.swift */,`), before the closing `);`:
```
					B10210 /* MeetingDetailPresentationTests.swift */,
```

6. **Add the app source to the app `Sources` build phase** — after line 790 (`A10207 ... BlockingProgressOverlay.swift in Sources`):
```
				A10208 /* MeetingDetailPresentation.swift in Sources */,
```

7. **Add the test source to the test `Sources` build phase (F10005)** — after line 918 (`CA1EAD0000000000000000C1 /* CalendarServiceTests.swift in Sources */,`), before the closing `);` at line 919:
```
				A10210 /* MeetingDetailPresentationTests.swift in Sources */,
```

- [ ] **Step 4: Remove the now-moved members from `RecordedMeetingView.swift` and wire to the free function**

Delete the file-private `ReviewPrimaryAction` enum (919-923) and the `TimeInterval.formattedRecordingDuration` extension (925-940) — they now live in the new file. (`formattedRecordingDuration` is used by `infoBar` and `recordingInspectorSection`; the extension is now visible module-wide, so call sites are unchanged.)

Replace the `primaryToolbarAction` computed property (569-585) body with a call to the free function, preserving its `recordingURL`/transcript/summary derivations:

```swift
    private var primaryToolbarAction: ReviewPrimaryAction? {
        reviewPrimaryAction(
            hasTranscript: meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasRecording: recordingURL != nil,
            hasSummary: meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            canSummarize: canSummarize,
            canExport: canExport
        )
    }
```

- [ ] **Step 5: Build and run the new tests**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingDetailPresentationTests 2>&1 | grep -E "Executed|error:"`
Expected: `Executed 12 tests, with 0 failures`. (Clean build.)

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Views/MeetingDetail/MeetingDetailPresentation.swift CasablancaTests/MeetingDetailPresentationTests.swift Casablanca/Views/RecordedMeetingView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "refactor(meeting-detail): extract ReviewPrimaryAction + duration formatting to pure, tested module"
```

(Note: the final single squashed commit message is in the closing section. If executing subagent-driven, intermediate commits are fine; the executor may choose to soft-reset and make one commit at the end. Either is acceptable as long as the final tree matches.)

---

## Task 2: Dedupe `presentExportAlert` into `ExportAlertPresenter.swift`

**Files:**
- Create: `Casablanca/Views/Components/ExportAlertPresenter.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift` (delete inline copy 877-894; calls become bare function calls)
- Modify: `Casablanca/Views/NotesEditorView.swift` (delete inline copy 474-491)
- Modify: `Casablanca.xcodeproj/project.pbxproj`

The two inline copies are byte-identical (verified). Extract verbatim as a free function.

- [ ] **Step 1: Create `ExportAlertPresenter.swift`**

```swift
import AppKit

/// Shared modal alert used after an export completes or fails. Optionally offers
/// a "Show in Finder" button when files were written to disk.
///
/// Extracted verbatim from the previously-duplicated `presentExportAlert`
/// methods in `RecordedMeetingView` and `NotesEditorView`.
func presentExportAlert(title: String, message: String, exportedURLs: [URL]) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message

    if exportedURLs.isEmpty {
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return
    }

    alert.addButton(withTitle: "Show in Finder")
    alert.addButton(withTitle: "OK")

    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting(exportedURLs)
    }
}
```

- [ ] **Step 2: Delete the inline copy in `RecordedMeetingView.swift`**

Delete the `private func presentExportAlert(title:message:exportedURLs:)` method (lines 877-894). Its three call sites inside `exportMeeting` (lines 632, 638, 645) already call `presentExportAlert(...)` unqualified — they now resolve to the free function. No call-site edits needed.

- [ ] **Step 3: Delete the inline copy in `NotesEditorView.swift`**

Delete the `private func presentExportAlert(title:message:exportedURLs:)` method (lines 474-491). Its call sites (452, 458, 465) call `presentExportAlert(...)` unqualified and now resolve to the free function. No call-site edits needed.

- [ ] **Step 4: Register `ExportAlertPresenter.swift` in `project.pbxproj`**

Pick fresh ID `A10209`/`B10209` (verify unused via grep). Edits:

1. PBXBuildFile (after the `A10208 ... MeetingDetailPresentation.swift in Sources` line added in Task 1):
```
		A10209 /* ExportAlertPresenter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10209 /* ExportAlertPresenter.swift */; };
```
2. PBXFileReference (after `B10208 ... MeetingDetailPresentation.swift`):
```
		B10209 /* ExportAlertPresenter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ExportAlertPresenter.swift; sourceTree = "<group>"; };
```
3. Add to the `E10011 /* Components */` group children (after `B10207 /* BlockingProgressOverlay.swift */,`, line 587):
```
				B10209 /* ExportAlertPresenter.swift */,
```
4. Add to the app `Sources` build phase (after the `A10208 ... in Sources` line):
```
				A10209 /* ExportAlertPresenter.swift in Sources */,
```

- [ ] **Step 5: Build to confirm both call sites resolve and there's no duplicate-symbol error**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' 2>&1 | grep -E "BUILD SUCCEEDED|error:"`
Expected: `** BUILD SUCCEEDED **`, no `error:` lines. (If a "duplicate declaration" or "ambiguous use of 'presentExportAlert'" appears, one inline copy wasn't fully deleted — fix before proceeding.)

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Views/Components/ExportAlertPresenter.swift Casablanca/Views/RecordedMeetingView.swift Casablanca/Views/NotesEditorView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "refactor(meeting-detail): dedupe presentExportAlert into shared ExportAlertPresenter"
```

---

## Task 3: Extract `MeetingDetailInspector` (stateless, lowest-risk view first)

**Files:**
- Create: `Casablanca/Views/MeetingDetail/MeetingDetailInspector.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift` (delete inspector members 693-799; call new subview from `.inspector` modifier)
- Modify: `Casablanca.xcodeproj/project.pbxproj`

The inspector reads only `meeting` and `canExport`. It uses `recordingURL` (give it its own private copy) and `formattedRecordingDuration` (now module-wide from Task 1) and `canExport` (passed in).

- [ ] **Step 1: Create `MeetingDetailInspector.swift` — move members verbatim**

```swift
import SwiftUI

struct MeetingDetailInspector: View {
    let meeting: Meeting
    let canExport: Bool

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                recordingInspectorSection

                if !meeting.participants.isEmpty {
                    participantsInspectorSection
                }

                exportInspectorSection
            }
            .padding(CasaSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundSecondary)
    }

    @ViewBuilder
    private var recordingInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Recording")

            if recordingURL != nil {
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved locally")
                            .font(.subheadline)
                            .foregroundStyle(Color.textPrimary)
                        if let duration = meeting.recordingDuration {
                            Text(duration.formattedRecordingDuration)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(CasaSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))

                // NOTE: A full inline audio player (waveform + scrubber) is deferred
                // to a later polish pass; "Show in Finder" is available in the ⋯ menu.
            } else {
                Text("No recording saved for this meeting.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var participantsInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Participants")

            ForEach(Array(meeting.participants.enumerated()), id: \.offset) { _, name in
                HStack(spacing: CasaSpace.sm) {
                    Text(initials(for: name))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.backgroundTertiary, in: Circle())
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var exportInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Export")

            if meeting.appleNotesSummaryNoteID != nil || meeting.appleNotesRawNotesNoteID != nil {
                Label("Exported to Apple Notes", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentSuccess)
                    .symbolRenderingMode(.hierarchical)
            } else if canExport {
                Text("Not exported yet. Use the Export action to save to your configured destination.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("Generate a summary or transcript to enable export.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func inspectorLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Color.textTertiary)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
```

- [ ] **Step 2: Delete inspector members from `RecordedMeetingView.swift` and call the subview**

Delete `inspector` (693-708), `recordingInspectorSection` (710-743), `participantsInspectorSection` (745-764), `exportInspectorSection` (766-786), `inspectorLabel` (788-793), `initials` (795-799).

In `body`, change the `.inspector` modifier (lines 38-41) from:
```swift
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 260, ideal: 320, max: 560)
        }
```
to:
```swift
        .inspector(isPresented: $showInspector) {
            MeetingDetailInspector(meeting: meeting, canExport: canExport)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 560)
        }
```

- [ ] **Step 3: Register `MeetingDetailInspector.swift` in `project.pbxproj`**

Fresh ID `A10211`/`B10211` (verify unused). Edits:
1. PBXBuildFile: `A10211 /* MeetingDetailInspector.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10211 /* MeetingDetailInspector.swift */; };`
2. PBXFileReference: `B10211 /* MeetingDetailInspector.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MeetingDetailInspector.swift; sourceTree = "<group>"; };`
3. Add `B10211 /* MeetingDetailInspector.swift */,` to the `E10210 /* MeetingDetail */` group children (created in Task 1).
4. Add `A10211 /* MeetingDetailInspector.swift in Sources */,` to the app `Sources` build phase.

- [ ] **Step 4: Build**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' 2>&1 | grep -E "BUILD SUCCEEDED|error:"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Views/MeetingDetail/MeetingDetailInspector.swift Casablanca/Views/RecordedMeetingView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "refactor(meeting-detail): extract MeetingDetailInspector"
```

---

## Task 4: Extract `MeetingSummaryTab`

**Files:**
- Create: `Casablanca/Views/MeetingDetail/MeetingSummaryTab.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift` (delete summary members; call subview in `readingColumn`)
- Modify: `Casablanca.xcodeproj/project.pbxproj`

Members to move: `summaryTab` (162-224), `summaryHero` (226-257), `parsedSection` (259-275), `bulletRow` (277-289), `actionItemsSection` (291-329), `renderedMarkdownSummary` (896-916), and the action-item↔todo helpers `matchingTodo`/`isActionItemCompleted`/`toggleActionItem` (654-689).

The parent's `summaryTab` references: `isSummarizingThisMeeting`, `summarizationService.statusMessage`, `meeting.summary`, `canSummarize`, and `summarizationService.summarizeInBackground(meeting:modelContext:)`. These become the injected props `isSummarizing`, `statusMessage`, `canSummarize`, `onSummarize`. The todo helpers need `modelContext` (env) and `meeting`.

- [ ] **Step 1: Create `MeetingSummaryTab.swift`**

```swift
import AppKit
import SwiftUI

struct MeetingSummaryTab: View {
    @Bindable var meeting: Meeting
    let isSummarizing: Bool
    let statusMessage: String
    let canSummarize: Bool
    let onSummarize: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        summaryTab
    }

    @ViewBuilder
    private var summaryTab: some View {
        if isSummarizing {
            HStack(spacing: CasaSpace.sm) {
                ProgressView()
                    .controlSize(.small)

                Text(statusMessage.isEmpty ? "Generating summary..." : statusMessage)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let summary = meeting.summary,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = SummaryResponseParser.parse(summary)

            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                summaryHero(parsed)

                if !parsed.decisions.isEmpty {
                    parsedSection("Decisions", systemImage: "diamond.fill") {
                        ForEach(Array(parsed.decisions.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "diamond.fill", color: Color.accentSuccess, text: text)
                        }
                    }
                }

                if !parsed.todoTexts.isEmpty {
                    actionItemsSection(parsed.todoTexts)
                }

                if !parsed.risks.isEmpty {
                    parsedSection("Risks & blockers", systemImage: "exclamationmark.triangle.fill") {
                        ForEach(Array(parsed.risks.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "exclamationmark.triangle.fill", color: Color.accentWarning, text: text)
                        }
                    }
                }

                if !parsed.followUps.isEmpty {
                    parsedSection("Follow-ups", systemImage: "arrow.turn.down.right") {
                        ForEach(Array(parsed.followUps.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "arrow.turn.down.right", color: Color.textSecondary, text: text)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "sparkles")
            } description: {
                Text("Generate a structured summary from the transcript and notes.")
            } actions: {
                if canSummarize {
                    Button("Summarize") {
                        onSummarize()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func summaryHero(_ parsed: SummaryResponseParser.ParsedResponse) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack {
                Label("AI Summary", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentSecondary)
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.summary ?? "", forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(GhostButtonStyle())
            }

            renderedMarkdownSummary(parsed.summary)
        }
        .padding(CasaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stateAIGenerated, in: RoundedRectangle(cornerRadius: CasaRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.xl)
                .strokeBorder(Color.accentSecondary.opacity(0.22), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func parsedSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.textTertiary)
                .symbolRenderingMode(.hierarchical)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func bulletRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(color)
            Text(text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actionItemsSection(_ texts: [String]) -> some View {
        let doneCount = texts.filter { isActionItemCompleted($0) }.count

        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack(spacing: CasaSpace.xs) {
                Label("Action items", systemImage: "checklist")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textTertiary)
                    .symbolRenderingMode(.hierarchical)

                Text("· \(doneCount) of \(texts.count) done")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                let completed = isActionItemCompleted(text)
                HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                    Button {
                        toggleActionItem(text)
                    } label: {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(completed ? Color.accentSuccess : Color.textTertiary)
                    }
                    .buttonStyle(.borderless)

                    Text(text)
                        .font(.body)
                        .strikethrough(completed)
                        .foregroundStyle(completed ? Color.textTertiary : Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderedMarkdownSummary(_ summary: String) -> some View {
        let rendered = MarkdownConverter.markdownToAttributedString(
            summary,
            baseFont: .systemFont(ofSize: NSFont.systemFontSize)
        )

        if !rendered.string.isEmpty {
            let attributed = AttributedString(rendered)
            Text(attributed)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(summary)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }

    // MARK: - Action item ↔ todo sync

    /// Finds the meeting-scoped `TodoItem` whose text matches a parsed action item.
    private func matchingTodo(for text: String) -> TodoItem? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return meeting.todos.first {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }
    }

    private func isActionItemCompleted(_ text: String) -> Bool {
        matchingTodo(for: text)?.isCompleted ?? false
    }

    /// Toggles a parsed action item's completion through the existing
    /// `ObsidianTodoSyncService` flow. If a meeting `TodoItem` already exists for
    /// the text, its `isCompleted` is flipped; otherwise a new completed todo is
    /// created (a check on a not-yet-tracked item).
    private func toggleActionItem(_ text: String) {
        if let todo = matchingTodo(for: text) {
            try? ObsidianTodoSyncService.setCompleted(
                !todo.isCompleted,
                for: todo,
                in: modelContext
            )
        } else {
            try? ObsidianTodoSyncService.createMeetingTodo(
                text: text,
                meeting: meeting,
                in: modelContext
            )
            if let created = matchingTodo(for: text) {
                try? ObsidianTodoSyncService.setCompleted(true, for: created, in: modelContext)
            }
        }
    }
}
```

- [ ] **Step 2: Delete moved members from `RecordedMeetingView.swift` and call the subview**

Delete from the parent: `summaryTab` (162-224), `summaryHero` (226-257), `parsedSection` (259-275), `bulletRow` (277-289), `actionItemsSection` (291-329), the action-item↔todo MARK section + `matchingTodo`/`isActionItemCompleted`/`toggleActionItem` (654-689), `renderedMarkdownSummary` (896-916).

In `readingColumn`, change the `.summary` case (lines 91-92) from:
```swift
            case .summary:
                summaryTab
```
to:
```swift
            case .summary:
                MeetingSummaryTab(
                    meeting: meeting,
                    isSummarizing: isSummarizingThisMeeting,
                    statusMessage: summarizationService.statusMessage,
                    canSummarize: canSummarize,
                    onSummarize: {
                        summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
                    }
                )
```

- [ ] **Step 3: Register `MeetingSummaryTab.swift` in `project.pbxproj`**

Fresh ID `A10212`/`B10212`. Edits: PBXBuildFile + PBXFileReference entries, add `B10212` to `E10210 /* MeetingDetail */` children, add `A10212 ... in Sources` to the app Sources build phase. (Same pattern as Task 3 Step 3.)

- [ ] **Step 4: Build**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' 2>&1 | grep -E "BUILD SUCCEEDED|error:"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Views/MeetingDetail/MeetingSummaryTab.swift Casablanca/Views/RecordedMeetingView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "refactor(meeting-detail): extract MeetingSummaryTab"
```

---

## Task 5: Extract `MeetingTranscriptTab`

**Files:**
- Create: `Casablanca/Views/MeetingDetail/MeetingTranscriptTab.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift` (delete transcript members; call subview)
- Modify: `Casablanca.xcodeproj/project.pbxproj`

Members to move: `transcriptTab` (333-423), `reapplyTerminology` (598-609), `restoreOriginalTranscript` (611-616), `canReapplyTerminology` (542-547). The transcript tab uses `terminologyService`, `onTranscribe`, `recordingURL` (own private copy), and `save()` (injected as `onSave`).

Note the original `transcriptTab` has slightly unusual indentation (the warning row and content blocks are over-indented and there's a stray closing brace structure). **Preserve the exact view tree, not the whitespace** — the indentation below is normalized but the view hierarchy is identical. (Whitespace-only changes inside a function body cannot affect layout.)

- [ ] **Step 1: Create `MeetingTranscriptTab.swift`**

```swift
import AppKit
import SwiftUI

struct MeetingTranscriptTab: View {
    @Bindable var meeting: Meeting
    let terminologyService: TerminologyService
    let onTranscribe: () -> Void
    let onSave: () -> Void

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var canReapplyTerminology: Bool {
        guard meeting.rawTranscript != nil else { return false }
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled) else { return false }
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        return !TerminologyService.parse(raw).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack {
                Label("Transcript", systemImage: "doc.text")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                if let transcript = meeting.transcript, !transcript.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if canReapplyTerminology {
                    Button {
                        Task { await reapplyTerminology() }
                    } label: {
                        Label("Re-apply terminology", systemImage: "wand.and.sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(terminologyService.isCorrecting)
                }

                if meeting.rawTranscript != nil {
                    Button {
                        restoreOriginalTranscript()
                    } label: {
                        Label("Restore original", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(terminologyService.isCorrecting)
                    .help("Replace the displayed transcript with the unmodified text from the recording, discarding any terminology corrections.")
                }
            }

            if let warning = terminologyService.warningMessage {
                HStack(alignment: .top, spacing: CasaSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.accentWarning)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        terminologyService.clearWarning()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(CasaSpace.sm)
                .background(Color.accentWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if let transcript = meeting.transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(transcript)
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(4)
                }
                .frame(maxHeight: 280)
            } else {
                ContentUnavailableView {
                    Label("No Transcript Yet", systemImage: "waveform")
                } description: {
                    Text("Transcribe the saved recording to review searchable text.")
                } actions: {
                    if recordingURL != nil {
                        Button("Transcribe") {
                            onTranscribe()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reapplyTerminology() async {
        guard let raw = meeting.rawTranscript else { return }
        let entries = TerminologyService.parse(
            UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )
        guard !entries.isEmpty else { return }

        let corrected = await terminologyService.correct(raw, entries: entries)
        guard meeting.modelContext != nil else { return }
        meeting.transcript = corrected
        onSave()
    }

    private func restoreOriginalTranscript() {
        guard let raw = meeting.rawTranscript else { return }
        meeting.transcript = raw
        terminologyService.clearWarning()
        onSave()
    }
}
```

- [ ] **Step 2: Delete moved members from `RecordedMeetingView.swift` and call the subview**

Delete: `transcriptTab` (333-423), `canReapplyTerminology` (542-547), `reapplyTerminology` (598-609), `restoreOriginalTranscript` (611-616).

**IMPORTANT — `canReapplyTerminology` and `reapplyTerminology` are ALSO used by `secondaryActionsMenu` (which STAYS in the parent, lines 821-828).** The parent's `secondaryActionsMenu` references `canReapplyTerminology` (821) and `reapplyTerminology()` (823). After moving these into the transcript tab, the parent loses them. Two options — choose the one that keeps behavior identical with least duplication:

- **Keep `canReapplyTerminology` and `reapplyTerminology` ALSO in the parent** (the transcript tab gets its own private copies; the parent keeps its copies for the menu). This is the safe, verbatim choice and is consistent with the `recordingURL` duplication decision. Both copies are pure derivations / service calls with no local state.

Apply this: leave the parent's `canReapplyTerminology` (542-547) and `reapplyTerminology` (598-609) **in place** (do NOT delete them); only delete `transcriptTab` (333-423) and `restoreOriginalTranscript` (611-616, used only by the transcript tab). The transcript tab carries its own copies as written in Step 1.

In `readingColumn`, change the `.transcript` case (93-94) from:
```swift
            case .transcript:
                transcriptTab
```
to:
```swift
            case .transcript:
                MeetingTranscriptTab(
                    meeting: meeting,
                    terminologyService: terminologyService,
                    onTranscribe: onTranscribe,
                    onSave: save
                )
```

- [ ] **Step 3: Register `MeetingTranscriptTab.swift` in `project.pbxproj`**

Fresh ID `A10213`/`B10213`. Same registration pattern (PBXBuildFile, PBXFileReference, add to `E10210` group children, add to app Sources build phase).

- [ ] **Step 4: Build**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' 2>&1 | grep -E "BUILD SUCCEEDED|error:"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Views/MeetingDetail/MeetingTranscriptTab.swift Casablanca/Views/RecordedMeetingView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "refactor(meeting-detail): extract MeetingTranscriptTab"
```

---

## Task 6: Extract `MeetingNotesTab` (HIGHEST RISK — WKWebView frame)

**Files:**
- Create: `Casablanca/Views/MeetingDetail/MeetingNotesTab.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift` (delete notesTab + isEditingNotes + saveTask + debouncedSave; call subview)
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**CRITICAL:** The `ToastMarkdownEditor(...).frame(minHeight: 160)` block and its enclosing `VStack(spacing: 0) { ... }.padding(CasaSpace.sm).background(Color.backgroundHover).clipShape(RoundedRectangle(cornerRadius: CasaRadius.md))` MUST be byte-identical to the original. Copy verbatim. If you cannot preserve it, STOP and escalate BLOCKED.

`isEditingNotes`, `saveTask`, and `debouncedSave()` move into this subview (they're used only by the notes tab). `save()` stays in the parent and is injected as `onSave`; `debouncedSave` calls `onSave` after its 500ms debounce.

- [ ] **Step 1: Create `MeetingNotesTab.swift`**

```swift
import SwiftUI

struct MeetingNotesTab: View {
    @Bindable var meeting: Meeting
    let onSave: () -> Void

    @State private var isEditingNotes = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack {
                Label("Notes", systemImage: "pencil.line")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                Button {
                    isEditingNotes.toggle()
                } label: {
                    Label(
                        isEditingNotes ? "Done" : "Edit",
                        systemImage: isEditingNotes ? "checkmark" : "pencil"
                    )
                    .font(.caption)
                }
                .buttonStyle(GhostButtonStyle())
            }

            if isEditingNotes {
                VStack(spacing: 0) {
                    ToastMarkdownEditor(
                        text: $meeting.userNotes,
                        placeholder: "Capture decisions, follow-ups, and context..."
                    )
                    .frame(minHeight: 160)
                    .onChange(of: meeting.userNotes) {
                        debouncedSave()
                    }
                }
                .padding(CasaSpace.sm)
                .background(Color.backgroundHover)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.md))
            } else if !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(meeting.userNotes)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
            } else {
                ContentUnavailableView {
                    Label("No Freeform Notes Yet", systemImage: "text.alignleft")
                } description: {
                    Text("Use freeform notes for ideas, follow-ups, and context that do not need timestamps.")
                } actions: {
                    Button("Edit Notes") {
                        isEditingNotes = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onSave()
        }
    }
}
```

**Self-check before moving on:** diff the `VStack(spacing: 0) { ToastMarkdownEditor(...).frame(minHeight: 160).onChange { debouncedSave() } }.padding(CasaSpace.sm).background(Color.backgroundHover).clipShape(...)` region against the original (lines 449-461). The ONLY differences must be leading-whitespace (indentation level). View tree, modifiers, order, and the `.frame(minHeight: 160)` must match exactly.

- [ ] **Step 2: Delete moved members from `RecordedMeetingView.swift` and call the subview**

Delete: `notesTab` (427-481), the `@State private var isEditingNotes` (15), `@State private var saveTask` (16), and `debouncedSave()` (853-860).

In `readingColumn`, change the `.notes` case (95-96) from:
```swift
            case .notes:
                notesTab
```
to:
```swift
            case .notes:
                MeetingNotesTab(meeting: meeting, onSave: save)
```

(`save()` stays in the parent — it's still used by `infoBar`'s language `.onChange`, `exportMeeting`, the parent's `reapplyTerminology`, etc.)

- [ ] **Step 3: Register `MeetingNotesTab.swift` in `project.pbxproj`**

Fresh ID `A10214`/`B10214`. Same registration pattern (PBXBuildFile, PBXFileReference, add to `E10210` group children, add to app Sources build phase).

- [ ] **Step 4: Build**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' 2>&1 | grep -E "BUILD SUCCEEDED|error:"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Full test suite (regression gate)**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' 2>&1 | grep -E "Executed|error:"`
Expected: `Executed N tests, with 0 failures` where N ≥ 398 (386 baseline + 12 new). If the ONLY failure is `RecordingInterruptionCoordinatorTests.testResumeMarksCorrectRecordEvenIfNewInterruptionAppended`, re-run once.

- [ ] **Step 6: Runtime verification of the Notes editor (WKWebView)**

Per project lesson: SwiftUI view changes can pass build+tests but break at runtime when a `WKWebView` is involved. Launch the app, open a completed meeting, switch to the **Notes** tab, click **Edit**, and confirm the markdown editor renders at full height (NOT collapsed to a sliver) and accepts typing. Use the `verify` or `run` skill to launch.

If the editor collapses: the frame structure was not preserved — revert this task and escalate BLOCKED.

- [ ] **Step 7: Commit**

```bash
git add Casablanca/Views/MeetingDetail/MeetingNotesTab.swift Casablanca/Views/RecordedMeetingView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "refactor(meeting-detail): extract MeetingNotesTab"
```

---

## Task 7: Final verification, line-count check, subagent review, squash/commit

**Files:** (verification only, then optional history tidy)

- [ ] **Step 1: Confirm parent line count and structure**

Run: `wc -l Casablanca/Views/RecordedMeetingView.swift`
Expected: ~280 lines (down from 941). Confirm what STAYED: `DetailTab`, `body`, `readingColumn`, `infoBar`, `pipelineBanner`, `pipelineStatusText`, `shouldShowPipelineBanner`, `toolbarButton`, `secondaryActionsMenu`, `hasNotes`/`canSummarize`/`canExport`/`recordingURL`/`isSummarizingThisMeeting`, `primaryToolbarAction` (now delegating to free fn), `summaryErrorBinding`, `exportMeeting`, `save`, `triggerAutomaticSummaryIfNeeded`, `didTriggerAutomaticSummary`, `selectedTab`, `showInspector`, and (per Task 5 decision) `canReapplyTerminology` + `reapplyTerminology` for the secondary menu.

- [ ] **Step 2: Confirm no orphaned references**

Run: `grep -rn "func presentExportAlert\|enum ReviewPrimaryAction\|formattedRecordingDuration" Casablanca/ | grep -v "MeetingDetailPresentation.swift\|ExportAlertPresenter.swift"`
Expected: only call sites of `formattedRecordingDuration` (in `RecordedMeetingView.swift` infoBar and `MeetingDetailInspector.swift`), and NO second `func presentExportAlert` / `enum ReviewPrimaryAction` definition. (i.e. exactly one definition of each, in the new files.)

- [ ] **Step 3: Subagent review (NON-SKIPPABLE per engineering rules)**

Dispatch a subagent (use `superpowers:requesting-code-review` or `/code-review`) to review the full diff against this plan, specifically checking: (a) every moved block is verbatim except interface adaptation; (b) the Notes-tab `ToastMarkdownEditor .frame(minHeight: 160)` + wrapping `VStack(spacing: 0)`/`padding`/`background`/`clipShape` is byte-identical to the original; (c) no behavior/layout change; (d) the two `presentExportAlert` copies were truly identical before merge; (e) pbxproj is well-formed (no duplicate IDs). Address any findings before finalizing.

- [ ] **Step 4: Final full test run**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' 2>&1 | grep -E "Executed|BUILD SUCCEEDED|error:"`
Expected: `Executed N tests, with 0 failures`, N ≥ 398. Record exact N for the report.

- [ ] **Step 5: Squash to one commit (if intermediate commits were made)**

The deliverable is a single commit. If Tasks 1-6 produced intermediate commits on the branch, soft-reset to the pre-Phase-4b HEAD and make one commit:

```bash
git reset --soft <pre-phase-4b-sha>
git add -A
git commit -m "$(cat <<'EOF'
refactor(meeting-detail): decompose RecordedMeetingView into focused subviews

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

(If the executor prefers to keep the per-task commits, that is acceptable too — but the final commit on the branch must carry the required message + Co-Authored-By trailer.)

- [ ] **Step 6: Report**

End with `Status: DONE`, exact test count, CONFIRM committed. Report: what moved where (file → original line ranges); the ExportAlertPresenter dedup (the two copies WERE byte-identical — state this); confirm the Notes-tab ToastMarkdownEditor frame is byte-identical; what stayed in the parent; before/after parent line count (941 → ~280). Include the subagent review outcome.

---

## Self-Review (run by plan author)

**1. Spec coverage:**
- `MeetingSummaryTab` (summaryTab + hero + parsedSection + bulletRow + actionItemsSection + renderedMarkdownSummary + todo helpers) → Task 4. ✓
- `MeetingTranscriptTab` (transcriptTab + warning + reapplyTerminology + restoreOriginalTranscript + canReapplyTerminology) → Task 5. ✓ (with the documented decision to keep parent copies of `canReapplyTerminology`/`reapplyTerminology` for `secondaryActionsMenu`).
- `MeetingNotesTab` (notesTab + isEditingNotes + saveTask + debouncedSave, frame byte-identical) → Task 6. ✓
- `MeetingDetailInspector` (inspector + 3 sections + inspectorLabel + initials, stateless) → Task 3. ✓
- `MeetingDetailPresentation` (ReviewPrimaryAction + primaryToolbarAction as pure fn + formattedRecordingDuration) → Task 1. ✓
- `ExportAlertPresenter` dedup → Task 2. ✓
- pbxproj registration + new MeetingDetail group → Tasks 1-6 (group created in Task 1). ✓
- `MeetingDetailPresentationTests` → Task 1. ✓
- Stays-in-parent list (Picker, selectedTab, showInspector, toolbar incl. secondaryActionsMenu, exportMeeting, save, triggerAutomaticSummaryIfNeeded, summary error alert, pipelineBanner) → Task 7 Step 1 confirms. ✓
- All tests green (≥386 baseline, ≥398 with new) → Tasks 6 & 7. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases". Task 4 Step 3 / Task 5 Step 3 / Task 6 Step 3 reference "same registration pattern as Task 3 Step 3" — this is acceptable because Task 3 Step 3 spells out all four concrete pbxproj edits explicitly; the pattern is mechanical ID substitution (A102xx/B102xx) and the group/build-phase anchors are identical. Each repeated step still names its exact fresh IDs and target group/phase.

**3. Type consistency:** `reviewPrimaryAction(hasTranscript:hasRecording:hasSummary:canSummarize:canExport:)` defined in Task 1 Step 1, tested in Task 1 Step 2, called in Task 1 Step 4 — signatures match. `presentExportAlert(title:message:exportedURLs:)` consistent across Task 2. Subview initializers (`MeetingSummaryTab`, `MeetingTranscriptTab`, `MeetingNotesTab`, `MeetingDetailInspector`) match the interface contracts and the call sites in Tasks 3-6. `onSave`/`save`, `onSummarize`, `onTranscribe` consistent.

**Ordering rationale:** Task 1 (pure logic, lowest risk, establishes group + IDs) → Task 2 (dedup, mechanical) → Task 3 (stateless inspector) → Task 4 (summary) → Task 5 (transcript, has the parent-copy nuance) → Task 6 (notes, highest risk, gated by full test run + runtime check) → Task 7 (verify + review + finalize). Each task builds and the suite is run at the riskiest point (Task 6) and again at the end (Task 7).
