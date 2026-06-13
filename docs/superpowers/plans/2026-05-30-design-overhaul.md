# Casablanca Design Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine Casablanca into a calmer, more mature, HIG-compliant "showcase quality" macOS app per the approved design spec (`docs/superpowers/specs/2026-05-30-design-overhaul-design.md`).

**Architecture:** Phased. Phase 1 establishes the visual foundation (system accent, materials, semantic state colors) every screen inherits. Phase 2 builds the testable logic units (summary section parser, sidebar time-bucketing, global search index, timestamped-notes removal + migration, prep-write). Phases 3–8 rebuild the views consuming that foundation/logic. Each phase is independently shippable.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, AppKit interop, WhisperKit, local LLM (Ollama/oMLX), XCTest. macOS app, Xcode project `Casablanca.xcodeproj`.

**Testing convention (follow the existing repo):** `CasablancaTests/` unit-tests **services and pure logic**, not SwiftUI views. So: logic tasks are TDD with real `XCTest` cases; view tasks are verified by a clean **build** (`xcodebuild`) plus **manual checks against the approved mockups** in `.superpowers/brainstorm/`. Do not fabricate view unit tests — none exist in this codebase.

**Build/test commands (use throughout):**
- Build: `xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' build`
- Test: `xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' test`
- Single test class: append `-only-testing:CasablancaTests/<ClassName>`

**⚠️ New-file registration (applies to every task that CREATES a `.swift` file):** this project uses a classic Xcode layout — there are **no** file-system-synchronized groups (`PBXFileSystemSynchronizedRootGroup` is absent from `project.pbxproj`). Each new file must be manually registered in `Casablanca.xcodeproj/project.pbxproj` in **four** places, for the correct target (app for `Casablanca/…`, `CasablancaTests` for test files): a `PBXBuildFile`, a `PBXFileReference`, a `PBXGroup` child entry, and the target's `Sources` build phase. Model `SummaryResponseParser.swift`'s existing four entries as the template. After adding, the build will fail with "cannot find type … in scope" if any of the four is missed. Created files in this plan: `MeetingTimeBucket.swift`, `MeetingSearchIndex.swift`, `MeetingPrepServiceWriteTests.swift`, `GlobalSearchView.swift`, `PrepEditorView.swift`, `OnboardingView.swift` (+ their test files).

---

## File Structure

**Phase 1 — Foundation**
- Modify: `Casablanca/Design/Theme.swift` — accent → `Color.accentColor`; state colors → semantic; surface-layer helpers.
- Modify: `Casablanca/Design/DesignTokens.swift` — radius bumps, layout constants (prep min/max).

**Phase 2 — Logic units**
- Modify: `Casablanca/Services/SummaryResponseParser.swift` — split all `##` sections.
- Create: `Casablanca/Services/MeetingTimeBucket.swift` — recency bucketing.
- Create: `Casablanca/Services/MeetingSearchIndex.swift` — global search over meetings + people + queue.
- Modify: `Casablanca/Models/Meeting.swift`, `Casablanca/Services/SummarizationService.swift`, `Casablanca/Views/*`, `Casablanca.xcodeproj/project.pbxproj` — remove timestamped notes.
- Modify: `Casablanca/Services/MeetingPrepService.swift` — write capability.
- Test: matching files under `CasablancaTests/`.

**Phases 3–8 — Views** (modify, per spec): `SidebarView`, `DashboardView`, `MeetingCardView`, `RecordedMeetingView`, `NotesEditorView`, `SettingsView`, `MarkdownTextEditor`; new: global-search overlay, prep-mode editor, onboarding flow.

---

## Phase 1 — Design Foundation

### Task 1.1: Honor the system accent color

**Files:**
- Modify: `Casablanca/Design/Theme.swift:38-44` (accent token block)

- [ ] **Step 1: Find every interactive use of the hardcoded accent**

Run: `grep -rn "accentPrimary\|accentPrimaryHover\|5B6EF5\|0.357.*0.431.*0.961" Casablanca/`
Expected: a list of usages across views + the token definitions. Note them — each must route through the system accent.

- [ ] **Step 2: Redefine the accent tokens as the system accent**

In `Theme.swift`, replace the hardcoded indigo definitions:

```swift
    // Accent — honor the user's System Settings accent color (HIG)
    static let accentPrimary = Color.accentColor
    static let accentPrimaryHover = Color.accentColor.opacity(0.85)
    static let accentSecondary = Color(nsColor: .systemPurple)  // AI / processing tint
```

- [ ] **Step 3: Replace direct color literals in views**

For each view hit from Step 1 that uses a raw indigo (not the token), switch it to `Color.accentColor` or `.accentPrimary`. Do not leave any `Color(red: 0.357...)` indigo literals for interactive UI.

- [ ] **Step 4: Build & verify**

Run the build command. Expected: builds clean.
Manual: change System Settings ▸ Appearance ▸ Accent (e.g. Pink, then Graphite); confirm primary buttons, selection, focus rings, and the Approvals badge all follow the chosen accent.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Design/Theme.swift Casablanca/Views
git commit -m "feat(design): honor system accent color (HIG)"
```

### Task 1.2: Semantic, calm state colors

**Files:**
- Modify: `Casablanca/Design/Theme.swift:42-51`

- [ ] **Step 1: Swap custom hexes for semantic system colors**

```swift
    static let accentSuccess = Color(nsColor: .systemGreen)
    static let accentWarning = Color(nsColor: .systemOrange)
    static let accentDanger  = Color(nsColor: .systemRed)

    // State (semantic; adapt to appearance & Increased Contrast)
    static let stateRecording  = accentDanger
    static let stateProcessing = accentSecondary
    static let stateLive       = accentSuccess
    static let stateIdle       = Color(nsColor: .tertiaryLabelColor)
    static let stateAIGenerated = accentSecondary.opacity(0.15)
```

- [ ] **Step 2: Build & verify**

Run build. Manual: toggle Light/Dark and enable Increased Contrast; confirm status dots, recording red, and AI/processing purple remain legible and adapt.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/Design/Theme.swift
git commit -m "feat(design): use semantic system colors for state"
```

### Task 1.3: Surface-layer materials & softer radii

**Files:**
- Modify: `Casablanca/Design/Theme.swift` (CardStyle), `Casablanca/Design/DesignTokens.swift` (CasaRadius, CasaLayout)

- [ ] **Step 1: Add prep width constants (don't redefine existing radii)**

Current tokens are `CasaRadius.sm=4, md=6, lg=8, xl=12` (`DesignTokens.swift:19-24`). The mockups use 12pt cards — that's the existing `xl`, so **do not redefine `lg`/`md`** (it would shift every current call site). Just add to `CasaLayout`:

```swift
    static let prepInspectorMin: CGFloat = 220
    static let prepInspectorMaxFraction: CGFloat = 0.5   // 50% of window width
```

- [ ] **Step 2: Give CardStyle the layered-material look**

Update `CardStyle` in `Theme.swift:56-73` to use a subtle translucent gradient fill + 1px hairline border + **`CasaRadius.xl`** (12), matching the approved mockups (gradient `white .06 → .03` over base, border `white .09`). Keep the highlighted accent bar. Existing `CasaRadius.lg` call sites elsewhere are left untouched.

- [ ] **Step 3: Build & verify**

Run build. Manual: confirm cards on the dashboard/detail show soft depth, 12pt radius, hairline border in both appearances.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Design
git commit -m "feat(design): layered-material cards, softer radii, prep width tokens"
```

---

## Phase 2 — Logic Units (TDD)

### Task 2.1: Parse all summary sections (not just Action Items)

**Files:**
- Modify: `Casablanca/Services/SummaryResponseParser.swift`
- Modify (exists): `CasablancaTests/SummaryResponseParserTests.swift` — already contains `test_malformedResponse` and `test_extraSectionsAfterActionItems_ignored` (lines ~65-81). **Keep `test_malformedResponse`; replace `test_extraSectionsAfterActionItems_ignored`** (its premise — that post-Action-Items sections are ignored — is intentionally reversed now) with `test_splitsAllSections` below.

- [ ] **Step 1: Add/replace failing tests for section splitting**

```swift
import XCTest
@testable import Casablanca

final class SummaryResponseParserTests: XCTestCase {
    func test_splitsAllSections() {
        let md = """
        # Summary
        Aligned on the plan.
        ## Decisions
        - Team Link owns mapping
        ## Action Items
        - Draft spec
        ## Risks and Blockers
        - Test env may slip
        ## Follow-ups
        - Ping Manon
        """
        let r = SummaryResponseParser.parse(md)
        XCTAssertTrue(r.summary.contains("Aligned on the plan."))
        XCTAssertEqual(r.todoTexts, ["Draft spec"])
        XCTAssertEqual(r.decisions, ["Team Link owns mapping"])
        XCTAssertEqual(r.risks, ["Test env may slip"])
        XCTAssertEqual(r.followUps, ["Ping Manon"])
    }

    func test_omitsEmptySections() {
        let md = "# Summary\nDone.\n## Action Items\n## Risks and Blockers\n"
        let r = SummaryResponseParser.parse(md)
        XCTAssertEqual(r.todoTexts, [])
        XCTAssertEqual(r.risks, [])
        XCTAssertEqual(r.decisions, [])
    }

    func test_backwardCompatible_noSections() {
        let r = SummaryResponseParser.parse("Just prose, no headers.")
        XCTAssertEqual(r.summary, "Just prose, no headers.")
        XCTAssertEqual(r.todoTexts, [])
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `xcodebuild ... test -only-testing:CasablancaTests/SummaryResponseParserTests`
Expected: FAIL — `decisions`/`risks`/`followUps` don't exist on `ParsedResponse`.

- [ ] **Step 3: Implement generalized section parsing**

Replace `SummaryResponseParser` with a version that: splits on `\n## ` headers into named sections; keeps everything before the first `##` as `summary`; extracts `- ` bullets per section. Shape:

```swift
enum SummaryResponseParser {
    struct ParsedResponse {
        let summary: String          // intro prose before the first "## " (unchanged semantics)
        let decisions: [String]
        let todoTexts: [String]      // Action Items (name kept for callers)
        let risks: [String]
        let followUps: [String]
        let rawMarkdown: String      // NEW: the full original response, for persistence + re-parse on display
    }

    static func parse(_ response: String) -> ParsedResponse {
        let sections = splitSections(response)         // [title: String : body: String]
        func bullets(_ title: String) -> [String] {
            guard let body = sections[title] else { return [] }
            return body.components(separatedBy: "\n").compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- ") else { return nil }
                let text = String(t.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        return ParsedResponse(
            summary: sections["__intro__"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? response.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: bullets("Decisions"),
            todoTexts: bullets("Action Items"),
            risks: bullets("Risks and Blockers"),
            followUps: bullets("Follow-ups"),
            rawMarkdown: response
        )
    }
    // splitSections: "__intro__" = text before first "## "; then each "## <Title>" → body until next "## " or EOF.
}
```

Implement `splitSections` to populate `__intro__` and each `## Title` body. **Preserve the existing `summary`+`todoTexts` semantics** so current callers keep working. The real consumers are `SummarizationService.swift:113` (returns the parsed result) and `RecordedMeetingView.swift:503-516` (`parsed.summary`, `parsed.todoTexts`). Add `rawMarkdown` as a new field (additive — won't break callers). The new test must also assert `r.rawMarkdown == md`.

- [ ] **Step 4: Run tests — verify pass**

Run the test command. Expected: PASS (all 3).

- [ ] **Step 5: Run full suite to confirm no regression**

Run full `test`. Expected: existing `SummarizationServiceTests` still pass.

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Services/SummaryResponseParser.swift CasablancaTests/SummaryResponseParserTests.swift
git commit -m "feat(summary): parse decisions/risks/follow-ups sections"
```

### Task 2.2: Sidebar time-bucketing utility

**Files:**
- Create: `Casablanca/Services/MeetingTimeBucket.swift`
- Test: `CasablancaTests/MeetingTimeBucketTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Casablanca

final class MeetingTimeBucketTests: XCTestCase {
    // Reference "now": Sat 2026-05-30 12:00, using a fixed calendar.
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private let now = ISO8601DateFormatter().date(from: "2026-05-30T12:00:00Z")!

    func test_futureIsUpcoming() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-30T15:00:00Z"), now: now), .upcoming)
    }
    func test_earlierTodayIsToday() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-30T09:00:00Z"), now: now), .today)
    }
    func test_earlierThisCalendarWeekIsThisWeek() {
        // Mon 2026-05-25 is same calendar week as Sat 2026-05-30
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-25T09:00:00Z"), now: now), .thisWeek)
    }
    func test_earlierThisMonth() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-05T09:00:00Z"), now: now), .thisMonth)
    }
    func test_earlierThisYear() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-03-04T09:00:00Z"), now: now), .thisYear)
    }
    func test_priorYear() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2025-11-01T09:00:00Z"), now: now), .earlier)
    }
}
```

- [ ] **Step 2: Run — verify fail** (`MeetingTimeBucket` undefined).

- [ ] **Step 3: Implement**

```swift
import Foundation

enum MeetingTimeBucket: String, CaseIterable {
    case upcoming, today, thisWeek, thisMonth, thisYear, earlier

    var title: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .thisYear: return "This Year"
        case .earlier: return "Earlier"
        }
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> MeetingTimeBucket {
        if date > now { return .upcoming }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return .thisYear }
        return .earlier
    }
}
```

Note: calendar-week boundary via `.weekOfYear` granularity; no "Yesterday" bucket (per spec). Add the new file to the Xcode target.

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/MeetingTimeBucket.swift CasablancaTests/MeetingTimeBucketTests.swift
git commit -m "feat(sidebar): meeting recency bucketing (calendar week)"
```

### Task 2.3: Global search index

**Files:**
- Create: `Casablanca/Services/MeetingSearchIndex.swift`
- Test: `CasablancaTests/MeetingSearchIndexTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Casablanca

final class MeetingSearchIndexTests: XCTestCase {
    func test_matchesTitleSummaryTranscriptAndPerson() {
        let m = Meeting(title: "Wegiz BgZ kickoff", date: .now)
        m.participants = ["Kim Owen-Jones", "Manon Koevoets"]
        m.summary = "Aligned on the BgZ exchange timeline."
        m.transcript = "the BgZ profile needs the FHIR mapping"
        let results = MeetingSearchIndex.search("bgz", in: [m])
        XCTAssertTrue(results.contains { $0.kind == .title })
        XCTAssertTrue(results.contains { $0.kind == .summary })
        XCTAssertTrue(results.contains { $0.kind == .transcript })

        let people = MeetingSearchIndex.search("kim", in: [m])
        XCTAssertTrue(people.contains { $0.kind == .person })
    }

    func test_snippetHighlightsMatch() {
        let m = Meeting(title: "Sync", date: .now)
        m.summary = "We aligned on the BgZ exchange timeline today."
        let r = MeetingSearchIndex.search("bgz", in: [m]).first { $0.kind == .summary }
        XCTAssertNotNil(r?.snippet)
        XCTAssertTrue(r!.snippet!.lowercased().contains("bgz"))
    }

    func test_caseInsensitiveAndEmptyQuery() {
        let m = Meeting(title: "Sync", date: .now)
        XCTAssertTrue(MeetingSearchIndex.search("", in: [m]).isEmpty)
    }
}
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement** a `MeetingSearchIndex` with `enum ResultKind { case title, summary, transcript, notes, person }`, a `SearchResult { meeting, kind, snippet?, person? }`, and `static func search(_ query:, in:[Meeting]) -> [SearchResult]`. Case-insensitive; empty/whitespace query → `[]`; `snippet` = ±40 chars around the first match for summary/transcript/notes; person matches scan `participants`. (Action-queue results integrate at the view layer via `ActionQueueModel`; keep this function meeting-focused and unit-testable.)

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/MeetingSearchIndex.swift CasablancaTests/MeetingSearchIndexTests.swift
git commit -m "feat(search): meeting+people search index with snippets"
```

### Task 2.4: Remove timestamped notes (model, prompt, UI threading, migration)

**Source files (all reference `timestampedNotes`/`TimestampedNote` — verified via grep):**
`Casablanca/Models/Meeting.swift`, `Casablanca/Services/SummarizationService.swift`,
`Casablanca/Services/AppleNotesBodyRenderer.swift` (~49-53), `Casablanca/Services/ObsidianMeetingExporter.swift` (~92-100,124), `Casablanca/Services/ExportService.swift` (~90 `canExport`),
`Casablanca/Views/NotesEditorView.swift`, `Casablanca/Views/RecordedMeetingView.swift`, `Casablanca/Views/SettingsView.swift`,
delete `Casablanca/Views/Components/TimestampedNotesHistorySection.swift`, edit `Casablanca.xcodeproj/project.pbxproj`.
**Test files to update:** `CasablancaTests/SummarizationServiceTests.swift`, `CasablancaTests/AppleNotesBodyRendererTests.swift`, `CasablancaTests/ExportServiceTests.swift`, and grep-check `CasablancaTests/MeetingStartFlowTests.swift` (may touch `showsTimestampedTools`).

- [ ] **Step 1: Update the tests first (they will fail to compile until impl is done)**

  - `SummarizationServiceTests.swift:6,23,29` — delete/rewrite `testRenderPromptKeepsFreeformBeforeTimestampedNotes`; remove the `timestampedNotes:` argument from any `renderPrompt(...)` call; add an assertion that the prompt renders from transcript + freeform notes only.
  - `AppleNotesBodyRendererTests.swift:8` — remove the `TimestampedNote(...)` construction and any assertion about a "Timestamped Notes" section.
  - `ExportServiceTests.swift:6,10-11,45,78,81-83` — delete/rewrite the three test methods built on timestamped notes.
  - `MeetingStartFlowTests.swift` — grep for `timestamped`/`showsTimestampedTools`; update if present.

- [ ] **Step 2: Remove the prompt token & assembly**

In `SummarizationService.swift`: delete the `Timestamped notes (optional history):\n{{timestamped_notes}}` lines from `defaultPromptTemplate`, delete the `timestampedNotes` local in `summarize()`, and remove the `timestampedNotes:` parameter from `renderPrompt` and its `{{timestamped_notes}}` substitution.

- [ ] **Step 3: Remove from the model**

In `Meeting.swift`: delete the `timestampedNotes` property (~line 97), the `self.timestampedNotes = []` line in `init` (~line 125), and the `TimestampedNote` type. SwiftData `@Model` property removal is a lightweight migration — no migration code needed; verified manually in Step 6.

- [ ] **Step 4: Remove the exporters' usage & UI**

  - `AppleNotesBodyRenderer.swift` — remove the timestamped-notes `<h2>`/section block.
  - `ObsidianMeetingExporter.swift` — remove `timestampedNotesSection` and its call site.
  - `ExportService.swift:~90` — drop `!meeting.timestampedNotes.isEmpty` from `canExport`.
  - Delete `TimestampedNotesHistorySection.swift` (and its `project.pbxproj` entries).
  - `NotesEditorView.swift` — remove: `enum MeetingNotesMode` (~103-108), `@State notesMode` (~158), the `notesMode` switch in `mainContent` (~280-287), the `Picker` (~337-343), `notesMode` resets (~212, ~801), `timestampedNotesArea` (~391-429), `timestampedNoteRow` (~431-450), `noteInputBar` (~452-483), `addTimestampedNote()` (~773-785), `showsTimestampedHistorySection` (~999-1001), `showsTimestampedTools` on the presentation struct (~33-35), and footer refs to `meeting.timestampedNotes` (~664-668, ~715-716). Leave the freeform editor only.
  - `RecordedMeetingView.swift` — remove the timestamped history display.
  - `SettingsView.swift` — remove any timestamped-notes preference.

- [ ] **Step 5: Build & run full suite**

Run build, then full test. Expected: builds clean; all updated tests pass; `grep -rn "timestampedNotes\|TimestampedNote" Casablanca/ CasablancaTests/` → empty.

- [ ] **Step 6: Manual migration check**

Launch the app against an existing data store (a prior meeting); confirm it opens without crash and summary still generates.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: remove timestamped notes (freeform-only)"
```

### Task 2.5: Prep-write capability in MeetingPrepService

`MeetingPrepService` is an `enum` of static methods (no init). It resolves the vault via
`AppPreferences.prepTodoStorage(in:)` + `ObsidianMeetingFiles.meetingFiles(for:userDefaults:)?.prepURL`.
Existing read API: `static loadPrepMarkdown(for:userDefaults:)`, `prepURL(for:userDefaults:)`,
`hasPrep(...)`. Existing tests configure it by setting `AppPreferenceKey.obsidianVaultPath` on a
`UserDefaults(suiteName:)` (see `MeetingPrepServiceTests.swift:7-25`). Mirror that.

**Files:**
- Modify: `Casablanca/Services/MeetingPrepService.swift` (add a static `writePrep`)
- Modify: `Casablanca/Models/Meeting.swift` (add `var localPrepNotes: String = ""` to the `@Model`)
- Test: create `CasablancaTests/MeetingPrepServiceWriteTests.swift` (register in pbxproj — see new-file note)

- [ ] **Step 1: Add `localPrepNotes` to the model**

In `Meeting.swift` add `var localPrepNotes: String = ""` (additive SwiftData property; lightweight migration). Do NOT remove anything.

- [ ] **Step 2: Write failing tests (mirroring the existing prep tests' setup)**

```swift
import XCTest
@testable import Casablanca

final class MeetingPrepServiceWriteTests: XCTestCase {
    func test_writesPrepToVaultThenReadsBack() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "prep-write-\(UUID().uuidString)")!
        defaults.set(tmp.path, forKey: AppPreferenceKey.obsidianVaultPath)
        defaults.set(PrepTodoStorage.obsidian.rawValue, forKey: AppPreferenceKey.prepTodoStorage) // match real key/enum

        let m = Meeting(title: "Daily standup",
                        date: ISO8601DateFormatter().date(from: "2026-05-30T11:00:00Z")!)
        try MeetingPrepService.writePrep("## Goal\nAlign on BgZ.", for: m, userDefaults: defaults)

        let read = MeetingPrepService.loadPrepMarkdown(for: m, userDefaults: defaults)
        XCTAssertEqual(read?.contains("Align on BgZ."), true)
    }

    func test_localOnlyModeStoresOnMeeting() throws {
        let defaults = UserDefaults(suiteName: "prep-local-\(UUID().uuidString)")!
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let m = Meeting(title: "Sync", date: .now)
        try MeetingPrepService.writePrep("notes", for: m, userDefaults: defaults)
        XCTAssertEqual(m.localPrepNotes, "notes")
    }
}
```

(After Step 4, confirm the exact `PrepTodoStorage` enum name/raw values and `AppPreferenceKey.prepTodoStorage` key against `AppPreferences`; adjust the two `defaults.set` lines to match.)

- [ ] **Step 3: Run — verify fail** (`writePrep` undefined, `localPrepNotes` undefined until Step 1).

- [ ] **Step 4: Implement the static write method**

```swift
static func writePrep(
    _ markdown: String,
    for meeting: Meeting,
    userDefaults: UserDefaults = .standard
) throws {
    if AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian,
       let url = prepURL(for: meeting, userDefaults: userDefaults) {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    } else {
        meeting.localPrepNotes = markdown          // local-only mode
    }
}
```

Keep the existing read/sync path intact. (Confirm `prepURL` returns the canonical writable `- Prep.md` path; it does, via `ObsidianMeetingFiles.prepURL`.)

- [ ] **Step 5: Run — verify pass; run full suite.**

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Services/MeetingPrepService.swift Casablanca/Models/Meeting.swift CasablancaTests/MeetingPrepServiceWriteTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(prep): write self-authored prep to vault / local"
```

---

## Phase 3 — Sidebar, Dashboard & Global Search (views)

Verification for all Phase 3+ tasks: clean build + manual check against the named mockup.

### Task 3.1: Sidebar with time buckets
**Files:** `Casablanca/Views/SidebarView.swift`
- [ ] **Step 1:** Group the meeting list using `MeetingTimeBucket.bucket(for:now:)`; render a section per non-empty bucket in order (`MeetingTimeBucket.allCases`), each with a `CasaSpace`-based uppercase label; status dot per row using semantic state color. Keep search field removed (moves to toolbar — Task 3.3).
- [ ] **Step 2:** Build. Manual vs mockup `screen-dashboard-v3.html`: buckets in order, empty buckets hidden, future under Upcoming.
- [ ] **Step 3:** Commit `feat(sidebar): group meetings by recency bucket`.

### Task 3.2: Dashboard "Up next" hero + cards
**Files:** `Casablanca/Views/DashboardView.swift`, `Casablanca/Views/Components/MeetingCardView.swift`
- [ ] **Step 1:** Add an "Up next" hero (accent-tinted card) surfacing the current/next meeting with primary `Start Recording` + secondary `Take Notes`. Restyle `MeetingCardView` to the layered-material card with participant avatars and hover actions.
- [ ] **Step 2:** Build. Manual vs `screen-dashboard-v2.html` hero + cards.
- [ ] **Step 3:** Commit `feat(dashboard): up-next hero and layered meeting cards`.

### Task 3.3: Global search overlay
**Files:** Create `Casablanca/Views/GlobalSearchView.swift`; modify `Casablanca/Views/ContentView.swift` (toolbar search field + `⌘F`).
- [ ] **Step 1:** Add a toolbar `.searchable`-style field / `⌘F` command that presents a Spotlight-style overlay over a dimmed `regularMaterial` background. Drive results from `MeetingSearchIndex.search` + `ActionQueueModel` items, grouped by `ResultKind` (+ People + Approvals), with highlighted snippets and `↑↓/↵/esc` keyboard handling. Selecting a result navigates (meeting → detail; person → filter). Remove the sidebar mini-search field.
- [ ] **Step 2:** Build. Manual vs `screen-search.html` + `screen-dashboard-v3.html` (People group): grouping, snippets, keyboard nav, accent selection.
- [ ] **Step 3:** Commit `feat(search): global ⌘F search overlay`.

---

## Phase 4 — Recorded-Meeting Detail (view)

### Task 4.1: Segmented detail + inspector + parsed sections
**Files:** `Casablanca/Views/RecordedMeetingView.swift`
- [ ] **Step 1 (persist full markdown — fixes the discard gap):** In `summarizeMeeting()` (line ~506), change `meeting.summary = parsed.summary` to `meeting.summary = parsed.rawMarkdown` so Risks/Follow-ups are no longer thrown away. `PendingTodoReview(summary:)` keeps using `parsed.summary` (intro). This is backward-compatible: existing meetings stored intro-only still render (their extra sections are simply empty when re-parsed).
- [ ] **Step 2 (render parsed sections):** In the body, compute `let parsed = SummaryResponseParser.parse(meeting.summary ?? "")` and render: AI summary hero (`parsed.summary`, `stateAIGenerated` tint) → **Decisions / Action items / Risks & blockers / Follow-ups** from `parsed.decisions/.todoTexts/.risks/.followUps`, each section omitted when empty. Replace the current single-markdown render at lines ~205-206.
- [ ] **Step 3 (layout):** Replace the two-column layout with a single reading column + a `Summary · Transcript · Notes` segmented control switching the main content, and a toggleable inspector holding audio player + participants + export status. Collapse secondary toolbar actions into `⋯`; keep one contextual primary action.
- [ ] **Step 4 (action-item → todo sync):** Action items render as checkboxes; toggling one creates/updates the corresponding `TodoItem` for this meeting via the same path used elsewhere (`ObsidianTodoSyncService`, as used in `NotesEditorView.swift:599,791` / `RecordedMeetingView`). Reuse the existing todo-creation flow rather than inventing a new one; if a meeting-scoped todo already exists for that text, toggle its `isCompleted`.
- [ ] **Step 5:** Build. Manual vs `screen-detail.html`: hero, section blocks (incl. Risks/Follow-ups now present), segmented switch, inspector toggle, contextual primary action; toggling an action-item checkbox reflects in the To-Dos list.
- [ ] **Step 6:** Commit `feat(detail): calm summary-first layout with parsed sections + inspector`.

---

## Phase 5 — Live Recording Workspace (view)

### Task 5.1: Calm recording bar + freeform-only notes
**Files:** `Casablanca/Views/NotesEditorView.swift`, `Casablanca/Views/Components/AudioLevelMeterView.swift`
- [ ] **Step 1:** Add the always-visible recording bar: pulsing `stateRecording` dot (respect Reduce Motion), tabular-numeral timer, inline audio meter, `Stop & Process` primary (`stop.fill`) + Pause (`pause.fill` ↔ `play.fill` + "Paused"); shortcuts `⌘P`/`⌘⏎`. Main area is the freeform `MarkdownTextEditor` (timestamped UI already removed in 2.4).
- [ ] **Step 2:** Build. Manual vs `screen-recording-v2.html` + `screen-recording-settings-v2.html` (icon glyphs).
- [ ] **Step 3:** Commit `feat(recording): calm always-on recording bar`.

### Task 5.2: Per-meeting device & language quick-control
**Files:** `Casablanca/Views/NotesEditorView.swift` (+ a small popover view)
- [ ] **Step 1:** Add the `🎙 <device> · <lang> ⌄` chip → vibrancy popover: input device list (with live meter on the selected device), system-audio toggle, transcription language list, footer link to Settings ▸ Recording. Wire device/language to the existing recording + transcription services; mid-recording language change re-tags subsequent audio (reuse the existing in-recording language switch). Show the same control in the pre-record state.
- [ ] **Step 2:** Build. Manual vs `screen-recording-settings-v2.html`: change device/language mid-recording.
- [ ] **Step 3:** Commit `feat(recording): per-meeting device & language quick-control`.

### Task 5.3: Focus mode
**Files:** `Casablanca/Views/NotesEditorView.swift`
- [ ] **Step 1:** Polish `recordingWorkspaceFocusMode`: hide sidebar/inspector/toolbar chrome, center notes at a comfortable measure, collapse recording state to a single pill (still pause/stop), `Esc` + button to exit. View-state only.
- [ ] **Step 2:** Build. Manual vs `screen-focus-mode.html`.
- [ ] **Step 3:** Commit `feat(recording): polished focus mode`.

### Task 5.4: Resizable Prep inspector
**Files:** `Casablanca/Views/NotesEditorView.swift`
- [ ] **Step 1:** Make the Prep divider draggable (resize cursor, hover highlight) constrained to `[CasaLayout.prepInspectorMin, window.width * CasaLayout.prepInspectorMaxFraction]`; persist width via `@AppStorage`. Keep `▣ Prep` toggle. Apply the same pattern to the detail inspector.
- [ ] **Step 2:** Build. Manual vs `screen-prep-resize.html`: drag to 50%, persists across relaunch.
- [ ] **Step 3:** Commit `feat(recording): drag-resizable prep inspector (≤50% width)`.

---

## Phase 6 — Preparation Mode (view)

### Task 6.1: Prep editor + Aa controls + formatting toolbar
**Files:** Create `Casablanca/Views/PrepEditorView.swift`; modify `Casablanca/Views/Components/MarkdownTextEditor.swift` (formatting toolbar + `Aa` size/width popover); add `Prepare` entry points in `DashboardView`/`MeetingCardView`/`SidebarView` context menu.
- [ ] **Step 1:** Build `PrepEditorView`: header (title/time/participants, "Upcoming · in N"), optional template (Goal · Agenda · Questions · Notes) or blank, the markdown editor + new formatting toolbar + `Aa` popover (text size 3 steps, width Comfortable/Full — persisted), calendar-context inspector, `✦ Draft with AI` (prep-oriented prompt via the LLM provider; result is editable), primary `Start Recording` + `Done`. Save through `MeetingPrepService.writePrep` (vault `- Prep.md` or local). Make the recording workspace Prep inspector open this editor inline (editable).
- [ ] **Step 2:** Build. Manual vs `screen-prep-mode.html` + `screen-notes-editor.html`: write prep, confirm it saves to vault and shows in the recording Prep inspector; `Draft with AI` produces editable text.
- [ ] **Step 3:** Commit `feat(prep): self-authored preparation mode`.

---

## Phase 7 — Settings & First-Run Onboarding (views)

### Task 7.1: Grouped settings + Recording tab
**Files:** `Casablanca/Views/SettingsView.swift`
- [ ] **Step 1:** Restructure into System-Settings-style inset rounded groups with labels; add a dedicated **Recording** tab (input device, system-audio capture, default transcription language, Whisper model) split from General/AI. Tabs: General · AI · Recording · Updates.
- [ ] **Step 2:** Build. Manual vs `screen-settings-onboarding.html` (left).
- [ ] **Step 3:** Commit `feat(settings): grouped layout + dedicated Recording tab`.

### Task 7.2: First-run onboarding flow
**Files:** Create `Casablanca/Views/OnboardingView.swift`; modify `CasablancaApp.swift` (present on first run; re-runnable from Settings).
- [ ] **Step 1:** 4 steps — Welcome (privacy) → Vault & export destination → Permissions (mic/system-audio/calendar with live granted status) → LLM check (detect running provider). Skippable; gated on a `@AppStorage` first-run flag; re-runnable via a Settings button.
- [ ] **Step 2:** Build. Manual vs `screen-settings-onboarding.html` (right): walk steps, live permission status, skippable, re-runnable.
- [ ] **Step 3:** Commit `feat(onboarding): first-run setup flow`.

---

## Phase 8 — Empty States, Loading & Feedback Polish (views)

### Task 8.1: Empty/loading/feedback pass
**Files:** `DashboardView`, `TodosView`, `ActionQueueView`, `TranscriptionView`, `GlobalSearchView`
- [ ] **Step 1:** Add designed empty states (no meetings / no calendar access / no todos / no approvals / no search results); replace bare `ProgressView`s with skeleton/loading states during transcription & summarization; add subtle transitions on approve/complete/export (respect Reduce Motion).
- [ ] **Step 2:** Build. Manual: trigger each empty/loading state.
- [ ] **Step 3:** Commit `feat(polish): empty states, loading skeletons, micro-feedback`.

---

## Final Verification (run after all phases)

- Full build + `xcodebuild ... test` green.
- `grep -rn "accentPrimary.*0.357\|timestampedNotes\|TimestampedNote" Casablanca/` → empty.
- Accent: switch System Settings accent → UI follows.
- Light/Dark + Increased Contrast + Reduce Motion all behave.
- Walk the full flow: onboarding → prepare a meeting → record (device/language/focus/resizable prep) → stop → transcribe → summarize (sectioned detail) → export → global search finds it by title, summary text, and participant.
