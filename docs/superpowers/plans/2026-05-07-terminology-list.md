# Terminology List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users maintain a global terminology list that post-corrects transcripts (deterministic dictionary replace + Ollama pass) and is injected into the summarization prompt.

**Architecture:** New `TerminologyService` slots a correction stage into the existing post-Stop pipeline in `TranscriptionView` between WhisperKit and the existing `saveTranscriptLocally`/`exportAutomaticallyIfEnabled`/summarization side effects. A new `Meeting.rawTranscript` field preserves the WhisperKit output. Settings exposes a global toggle + plain-text list editor. Pipeline runs entirely in the existing background `Task`; nothing blocks the UI.

**Tech Stack:** Swift, SwiftUI, SwiftData, WhisperKit (existing), Ollama HTTP API (existing), `@AppStorage` / `UserDefaults`, `@Observable`, `NSRegularExpression`.

**Spec:** `docs/superpowers/specs/2026-05-07-terminology-list-design.md`

**Test target:** The Xcode project has no unit-test target. All verification is manual + Xcode build. Pure functions in `TerminologyService` are written to be easy to test if a target is added later, but no test code is required for this feature.

---

## File Structure

**Create:**
- `Casablanca/Services/TerminologyService.swift` — entry struct, parser, dictionary-replace, Ollama correction client, observable state.

**Modify:**
- `Casablanca/Models/Meeting.swift` — add 2 keys to `AppPreferenceKey`; add `var rawTranscript: String?` to the `Meeting` `@Model`.
- `Casablanca/Services/SummarizationService.swift` — update `renderPrompt` to accept and substitute `{{terminology_list}}`; update `summarize(meeting:)` to compute and pass the block; extend `defaultPromptTemplate`.
- `Casablanca/CasablancaApp.swift` (or wherever `AppModel` is defined) — instantiate and hold a `TerminologyService`.
- `Casablanca/Views/TranscriptionView.swift` — insert correction stage in `startTranscription()`.
- `Casablanca/Views/SettingsView.swift` — add Terminology section + sheet editor.
- `Casablanca/Views/RecordedMeetingView.swift` — extend pipeline banner; render warning notice; add re-apply button.

---

## Task 1: Add preferences + `Meeting.rawTranscript`

**Files:**
- Modify: `Casablanca/Models/Meeting.swift:4-15` (AppPreferenceKey), `Casablanca/Models/Meeting.swift:86` (Meeting model body)

- [ ] **Step 1: Add new preference keys**

In `Casablanca/Models/Meeting.swift`, replace the `AppPreferenceKey` enum (lines 4–15) with:

```swift
enum AppPreferenceKey {
    static let obsidianVaultPath = "obsidianVaultPath"
    static let ollamaEndpoint = "ollamaEndpoint"
    static let ollamaModel = "ollamaModel"
    static let whisperModel = "whisperModel"
    static let defaultTranscriptionLanguage = "defaultTranscriptionLanguage"
    static let summaryPromptTemplate = "summaryPromptTemplate"
    static let autoExportNotesToObsidian = "autoExportNotesToObsidian"
    static let autoSummarizeAfterTranscription = "autoSummarizeAfterTranscription"
    static let defaultRecordingInputDeviceID = "defaultRecordingInputDeviceID"
    static let recordingWorkspaceFocusMode = "recordingWorkspaceFocusMode"
    static let terminologyCorrectionEnabled = "terminologyCorrectionEnabled"
    static let terminologyList = "terminologyList"
}
```

- [ ] **Step 2: Add `rawTranscript` to the Meeting model**

In the same file, immediately below `var transcript: String?` at line 86, add:

```swift
    var rawTranscript: String?
```

The `init` does not need updating — SwiftData treats new optional properties as `nil` by default; this is a lightweight migration with no schema-version bump.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Models/Meeting.swift
git commit -m "feat(terminology): add preference keys and Meeting.rawTranscript"
```

---

## Task 2: Create `TerminologyService` — pure functions

**Files:**
- Create: `Casablanca/Services/TerminologyService.swift`

- [ ] **Step 1: Create the file with the entry struct, parser, dictionary-replace, formatter**

Create `Casablanca/Services/TerminologyService.swift`:

```swift
import Foundation

struct TerminologyEntry: Equatable {
    let canonical: String
    let aliases: [String]
}

@MainActor
@Observable
final class TerminologyService {
    private(set) var isCorrecting = false
    var warningMessage: String?

    func clearWarning() {
        warningMessage = nil
    }

    static func parse(_ raw: String) -> [TerminologyEntry] {
        var entries: [TerminologyEntry] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let canonical = parts[0].trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }

            var aliases: [String] = []
            if parts.count == 2 {
                aliases = parts[1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            entries.append(TerminologyEntry(canonical: canonical, aliases: aliases))
        }
        return entries
    }

    static func dictionaryReplace(_ text: String, entries: [TerminologyEntry]) -> String {
        // Build (alias, canonical) pairs, sorted by alias length descending,
        // ties broken by entry order in `entries`.
        var pairs: [(alias: String, canonical: String, order: Int)] = []
        for (index, entry) in entries.enumerated() {
            for alias in entry.aliases {
                pairs.append((alias: alias, canonical: entry.canonical, order: index))
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.alias.count != rhs.alias.count {
                return lhs.alias.count > rhs.alias.count
            }
            return lhs.order < rhs.order
        }

        var result = text
        for pair in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: pair.alias)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            // escapedTemplate ensures `$`/`\` in the canonical aren't interpreted as backreferences.
            let template = NSRegularExpression.escapedTemplate(for: pair.canonical)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    static func formattedForPrompt(_ entries: [TerminologyEntry]) -> String {
        entries.map { "- \($0.canonical)" }.joined(separator: "\n")
    }

    static func renderTerminologyBlock(enabled: Bool, raw: String) -> String {
        guard enabled else { return "" }
        let entries = parse(raw)
        guard !entries.isEmpty else { return "" }
        return """
        Domain terminology to preserve (use these exact spellings):
        \(formattedForPrompt(entries))
        """
    }
}
```

- [ ] **Step 2: Register the new file with the Xcode project**

`Casablanca.xcodeproj/project.pbxproj` lists every Swift file explicitly — new files are NOT auto-included. The repo provides a helper script. Run from the workspace root:

```bash
scripts/add-to-xcode.rb Casablanca Casablanca/Services/TerminologyService.swift
```

Expected output: a line confirming the file was added (or `already in project: ...` if rerunning). The script is idempotent.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

(Or in Xcode: ⌘B.)
Expected: `BUILD SUCCEEDED`. If you see `Cannot find 'TerminologyService' in scope` later, return to Step 2 — the file was not registered.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Services/TerminologyService.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(terminology): add TerminologyService with parse, dictionary-replace, prompt formatter"
```

**Note on shape divergence from spec:** the spec sketched `enum TerminologyService` with all-static members. The plan upgrades to `final class` because we need `@Observable` instance state (`isCorrecting`, `warningMessage`) for the pipeline banner and warning notice in `RecordedMeetingView`. Pure helpers stay `static`. This is a deliberate refinement, not a regression.

---

## Task 3: Add Ollama correction call to `TerminologyService`

**Files:**
- Modify: `Casablanca/Services/TerminologyService.swift`

- [ ] **Step 1: Add private Ollama request/response shapes**

Inside `TerminologyService`, add at the top of the class body (above `isCorrecting`):

```swift
    private struct OllamaGenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let options: Options
        struct Options: Encodable { let temperature: Double }
    }

    private struct OllamaGenerateResponse: Decodable {
        let response: String?
        let error: String?
    }

    enum TerminologyError: Error {
        case invalidEndpoint
        case requestFailed(String)
        case emptyResponse
    }
```

- [ ] **Step 2: Add the `correct` instance method**

Add to the same class:

```swift
    /// Corrects `rawTranscript` against `entries`. Never throws — on any failure,
    /// returns the dictionary-replaced text and surfaces a `warningMessage`.
    /// `entries` is captured by value: edits to the underlying preference made
    /// after this call begins do not affect this run.
    func correct(_ rawTranscript: String, entries: [TerminologyEntry]) async -> String {
        guard !entries.isEmpty else { return rawTranscript }

        isCorrecting = true
        defer { isCorrecting = false }

        let dictionaryReplaced = Self.dictionaryReplace(rawTranscript, entries: entries)

        if Task.isCancelled { return dictionaryReplaced }

        do {
            return try await runOllamaPass(transcript: dictionaryReplaced, entries: entries)
        } catch {
            warningMessage = "Terminology correction is unavailable; transcript reflects only deterministic replacements."
            return dictionaryReplaced
        }
    }

    private func runOllamaPass(transcript: String, entries: [TerminologyEntry]) async throws -> String {
        guard let url = makeGenerateURL() else {
            throw TerminologyError.invalidEndpoint
        }

        let prompt = """
        You are correcting domain-specific terminology in a meeting transcript.

        The following terms must appear with their exact spelling:
        \(Self.formattedForPrompt(entries))

        Rules:
        - Fix only misspellings or phonetic mistranscriptions of the terms above.
        - Do not rephrase, translate, summarize, add, or remove anything else.
        - Preserve all timestamps, speaker labels, line breaks, and punctuation exactly.
        - Output only the corrected transcript. No preamble, no commentary.

        Transcript:
        \(transcript)
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(
            OllamaGenerateRequest(
                model: UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaModel) ?? "llama3.2",
                prompt: prompt,
                stream: false,
                options: .init(temperature: 0)
            )
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TerminologyError.requestFailed(error.localizedDescription)
        }

        if Task.isCancelled { throw CancellationError() }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TerminologyError.requestFailed("Ollama returned an invalid response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TerminologyError.requestFailed("Ollama returned status \(httpResponse.statusCode).")
        }

        let payload = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        if let err = payload.error, !err.isEmpty {
            throw TerminologyError.requestFailed(err)
        }
        let corrected = payload.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !corrected.isEmpty else {
            throw TerminologyError.emptyResponse
        }
        return corrected
    }

    private func makeGenerateURL() -> URL? {
        let endpoint = UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434"
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("/api/generate") { return URL(string: trimmed) }
        if trimmed.hasSuffix("/api") { return URL(string: "\(trimmed)/generate") }
        if trimmed.hasSuffix("/") { return URL(string: "\(trimmed)api/generate") }
        return URL(string: "\(trimmed)/api/generate")
    }
```

(The URL builder is duplicated from `SummarizationService` rather than shared, to avoid coupling the two services for a one-method overlap. If a third caller appears later, factor it out.)

- [ ] **Step 3: Build**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Services/TerminologyService.swift
git commit -m "feat(terminology): add Ollama correction pass with timeout and cancellation"
```

---

## Task 4: Hold `TerminologyService` on `AppModel`

**Files:**
- Modify: `Casablanca/CasablancaApp.swift` (the `AppModel` class is declared inline in this file around lines 93–110)

- [ ] **Step 1: Add `terminologyService` to `AppModel`**

Open `Casablanca/CasablancaApp.swift`. Find the `final class AppModel { ... }` block. Just below `let summarizationService = SummarizationService()` (around line 100), add:

```swift
    let terminologyService = TerminologyService()
```

`AppModel` is already injected via `.environment(appModel)` at the root of the SwiftUI hierarchy, so any view declaring `@Environment(AppModel.self)` automatically picks it up — no additional wiring needed.

- [ ] **Step 2: Build**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/CasablancaApp.swift
git commit -m "feat(terminology): hold TerminologyService on AppModel"
```

---

## Task 5: Update `SummarizationService` to inject the terminology block

**Files:**
- Modify: `Casablanca/Services/SummarizationService.swift:37-63` (default template), `:80-153` (`summarize(meeting:)`), `:222-242` (`renderPrompt`)

- [ ] **Step 1: Update `defaultPromptTemplate`**

Replace the `defaultPromptTemplate` literal (lines 37–63) with:

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

    {{terminology_list}}

    Meeting title: {{title}}
    Scheduled time: {{scheduled_time}}

    Transcript:
    {{transcript}}

    Freeform notes:
    {{freeform_notes}}

    Timestamped notes (optional history):
    {{timestamped_notes}}
    """
```

- [ ] **Step 2: Extend `renderPrompt` signature**

Replace the `renderPrompt` function (lines 222–242) with:

```swift
    static func renderPrompt(
        template: String,
        meeting: Meeting,
        transcript: String,
        timestampedNotes: String,
        freeformNotes: String,
        terminologyBlock: String
    ) -> String {
        let formattedDate = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: meeting.date)
        }()

        return template
            .replacingOccurrences(of: "{{title}}", with: meeting.title)
            .replacingOccurrences(of: "{{scheduled_time}}", with: formattedDate)
            .replacingOccurrences(of: "{{transcript}}", with: transcript.isEmpty ? "None" : transcript)
            .replacingOccurrences(of: "{{timestamped_notes}}", with: timestampedNotes.isEmpty ? "None" : timestampedNotes)
            .replacingOccurrences(of: "{{freeform_notes}}", with: freeformNotes.isEmpty ? "None" : freeformNotes)
            .replacingOccurrences(of: "{{terminology_list}}", with: terminologyBlock)
    }
```

- [ ] **Step 3: Update `summarize(meeting:)` to compute and pass the block**

Replace the existing `let prompt = Self.renderPrompt(...)` block (around lines 101–107) with:

```swift
        let terminologyBlock = TerminologyService.renderTerminologyBlock(
            enabled: UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled),
            raw: UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )

        let prompt = Self.renderPrompt(
            template: UserDefaults.standard.string(forKey: AppPreferenceKey.summaryPromptTemplate) ?? Self.defaultPromptTemplate,
            meeting: meeting,
            transcript: transcript,
            timestampedNotes: timestampedNotes,
            freeformNotes: freeformNotes,
            terminologyBlock: terminologyBlock
        )
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. If you get "missing argument for parameter 'terminologyBlock' in call", search for any other callers of `renderPrompt` (`grep -rn "renderPrompt(" Casablanca`) — there should only be the one in `summarize(meeting:)`. Update any others to pass `terminologyBlock: ""` if they exist.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Services/SummarizationService.swift
git commit -m "feat(terminology): inject terminology block into summary prompt"
```

---

## Task 6: Insert correction stage in the post-Stop pipeline

**Files:**
- Modify: `Casablanca/Views/TranscriptionView.swift:134-168` (`startTranscription`)

- [ ] **Step 1: Inject the terminology service into the view**

At the top of `TranscriptionView` (after the existing `@Environment(\.modelContext)` line ~10), add:

```swift
    @Environment(AppModel.self) private var appModel
    private var terminologyService: TerminologyService { appModel.terminologyService }
```

- [ ] **Step 2: Replace the inner `do { ... }` block of `startTranscription()`**

Replace lines 145–167 (the body inside `do { ... }` plus the catch blocks — keep the outer `guard !didStart`, `didStart = true`, and `recordingPath` guard untouched). New body:

```swift
        do {
            meeting.status = .processing
            save()

            let result = try await transcriptionService.transcribe(fileURL: fileURL, localeIdentifier: meeting.transcriptionLanguage)

            let correctionEnabled = UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled)
            let terminologyRaw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
            let entries = correctionEnabled ? TerminologyService.parse(terminologyRaw) : []

            let finalTranscript: String
            if !entries.isEmpty {
                meeting.rawTranscript = result.formattedTranscript
                save()
                let corrected = await terminologyService.correct(result.formattedTranscript, entries: entries)
                // Guard against the meeting being deleted mid-correction.
                guard meeting.modelContext != nil else { return }
                finalTranscript = corrected
            } else {
                meeting.rawTranscript = nil
                finalTranscript = result.formattedTranscript
            }

            meeting.transcript = finalTranscript
            meeting.status = .completed
            save()

            _ = try? TranscriptionService.saveTranscriptLocally(meeting: meeting, result: result)
            ExportService.exportAutomaticallyIfEnabled(meeting)

            onComplete()
        } catch is CancellationError {
            // User cancelled — handled by cancel button
        } catch let transcriptionError as TranscriptionError {
            error = transcriptionError
            didStart = false
        } catch {
            self.error = .transcriptionFailed(error.localizedDescription)
            didStart = false
        }
```

Note: `saveTranscriptLocally` writes a WhisperKit-segmented transcript file from the `result` object — by design, this is the raw segmented form, not the corrected text. That's acceptable: the corrected text is what gets persisted on `meeting.transcript`, displayed in the UI, and exported via `ExportService.exportAutomaticallyIfEnabled(meeting)` (which reads `meeting.transcript`). No change needed.

`meeting.modelContext` is synthesized by SwiftData's `@Model` macro as an optional `ModelContext?`. `meeting.modelContext != nil` is a valid runtime check that the meeting is still attached to a live store (i.e. has not been deleted).

- [ ] **Step 3: Build**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Views/TranscriptionView.swift
git commit -m "feat(terminology): run correction stage between transcription and export"
```

---

## Task 7: Settings UI — Terminology section + sheet editor

**Files:**
- Modify: `Casablanca/Views/SettingsView.swift:5-19` (state + storage), `:188-201` (AI tab Summary Prompt section), `:280-318` (sheet area)

- [ ] **Step 1: Add `@AppStorage` and `@State`**

Below the existing `@AppStorage(AppPreferenceKey.summaryPromptTemplate) ...` line (line 13), add:

```swift
    @AppStorage(AppPreferenceKey.terminologyCorrectionEnabled) private var terminologyCorrectionEnabled = false
    @AppStorage(AppPreferenceKey.terminologyList) private var terminologyList = ""
```

Below `@State private var isEditingSummaryPrompt = false` (line 19), add:

```swift
    @State private var isEditingTerminologyList = false
```

- [ ] **Step 2: Add the Terminology section**

Immediately after the closing `}` of the `Section("Summary Prompt") { ... }` block (line 201), add a new `Section`:

```swift
            Section("Terminology") {
                Toggle("Correct terminology after transcription", isOn: $terminologyCorrectionEnabled)

                Text("Domain-specific terms that are often misspelled by the transcriber. One term per line. Use a colon to list common misspellings, e.g.:\n    Medicore: Mediscore, Medi-Core")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Customize Terminology List...") {
                    isEditingTerminologyList = true
                }
                .buttonStyle(SecondaryButtonStyle())

                Text("When the toggle is on and the list is non-empty, Casablanca runs a deterministic find/replace plus a low-temperature Ollama pass on each new transcript before summarization.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
```

- [ ] **Step 3: Attach the sheet**

Find the existing `.sheet(isPresented: $isEditingSummaryPrompt) { summaryPromptSheet }` modifier (line 204). Add a second sheet modifier directly below it:

```swift
        .sheet(isPresented: $isEditingTerminologyList) {
            terminologyListSheet
        }
```

- [ ] **Step 4: Implement `terminologyListSheet`**

Below the existing `summaryPromptSheet` private property (ends around line 318), add:

```swift
    private var terminologyListSheet: some View {
        VStack(alignment: .leading, spacing: CasaSpace.lg) {
            HStack {
                VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                    Text("Customize Terminology List")
                        .font(.title3.weight(.semibold))
                    Text("One term per line. Optional aliases follow a colon, comma-separated.")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()

                Button("Done") {
                    isEditingTerminologyList = false
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            TextEditor(text: $terminologyList)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)

            Text("Examples:\n    Medicore: Mediscore, Medi-Core\n    Wegiz BgZ: Wegis, BGZ\n    Orchestra\n\nLines starting with `#` are ignored.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset to Empty") {
                    terminologyList = ""
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(terminologyList.isEmpty)

                Spacer()
            }
        }
        .padding(CasaSpace.xl)
        .frame(minWidth: 640, minHeight: 440)
    }
```

- [ ] **Step 5: Build and smoke-test the UI**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Then run the app. Open Settings → AI. Verify:
- The Terminology section appears below Summary Prompt.
- The toggle persists across app restarts (toggle on, quit, relaunch — should still be on).
- "Customize Terminology List…" opens the sheet, the editor accepts input, "Done" dismisses, content persists.
- "Reset to Empty" is greyed out when empty, active when non-empty.

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Views/SettingsView.swift
git commit -m "feat(terminology): add Settings section with toggle and list editor"
```

---

## Task 8: `RecordedMeetingView` — pipeline banner + warning surface

**Files:**
- Modify: `Casablanca/Views/RecordedMeetingView.swift:13` (services accessor), `:386-407` (pipeline banner state + text), and the `transcriptCard` (`:226-275`)

- [ ] **Step 1: Add accessor for the terminology service**

Below the existing `private var summarizationService: SummarizationService { appModel.summarizationService }` line (line 13), add:

```swift
    private var terminologyService: TerminologyService { appModel.terminologyService }
```

- [ ] **Step 2: Extend `shouldShowPipelineBanner`**

Replace the `shouldShowPipelineBanner` computed property (lines 386–391) with:

```swift
    private var shouldShowPipelineBanner: Bool {
        terminologyService.isCorrecting
            || summarizationService.isSummarizing
            || (autoSummarizeAfterTranscription
                && meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
    }
```

- [ ] **Step 3: Extend `pipelineStatusText`**

Replace the `pipelineStatusText` computed property (lines 393–407) with:

```swift
    private var pipelineStatusText: String {
        if terminologyService.isCorrecting {
            return "Correcting terminology..."
        }

        if summarizationService.isSummarizing {
            return summarizationService.statusMessage.isEmpty ? "Generating summary..." : summarizationService.statusMessage
        }

        if autoSummarizeAfterTranscription && autoExportNotesToObsidian {
            return "Casablanca is moving this meeting through summary and export automatically."
        }

        if autoSummarizeAfterTranscription {
            return "Casablanca will generate the summary automatically."
        }

        return "The next recommended step is ready in the toolbar."
    }
```

- [ ] **Step 4: Update the pipeline banner spinner gating**

The existing `pipelineBanner` (around line 153) only shows the spinner when `summarizationService.isSummarizing` — without this change, the terminology-correction state shows the static "sparkles" icon instead of activity. Find the line:

```swift
                if summarizationService.isSummarizing {
```

and change it to:

```swift
                if summarizationService.isSummarizing || terminologyService.isCorrecting {
```

- [ ] **Step 5: Render the warning notice in `transcriptCard`**

Inside `transcriptCard` (line 226), update the `VStack(alignment: .leading, spacing: CasaSpace.md) { ... }` body. Directly after the closing `}` of the existing top `HStack { Label("Transcript"...) }` (the row with the Copy button, ending around line 246) and **before** the `if let transcript = ...` block, insert:

```swift
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
```

`Color.accentWarning` is defined in the project's design tokens (`Casablanca/Design/Theme.swift`); no fallback needed.

- [ ] **Step 6: Build**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Smoke-test the warning surface**

Visual verification of the warning notice (functional verification of `isCorrecting` happens in Task 10). Temporarily replace the `.task(id: meeting.id) { await triggerAutomaticSummaryIfNeeded() }` modifier on `body` with:

```swift
        .task(id: meeting.id) {
            terminologyService.warningMessage = "Test warning — remove me"
            await triggerAutomaticSummaryIfNeeded()
        }
```

Run the app and open any recorded meeting. Confirm the yellow warning row renders above the transcript and the X dismiss button clears it. **Revert the `.task` modifier to its original form before continuing.**

- [ ] **Step 8: Commit**

```bash
git add Casablanca/Views/RecordedMeetingView.swift
git commit -m "feat(terminology): show correction status in pipeline banner and warning notice"
```

---

## Task 9: `RecordedMeetingView` — Re-apply terminology action

**Files:**
- Modify: `Casablanca/Views/RecordedMeetingView.swift` (transcriptCard around `:226-275`, plus a new private async function)

- [ ] **Step 1: Add the re-apply button to the transcript card header**

In `transcriptCard`, locate the existing top `HStack { Label("Transcript"...) ... if let transcript ... Copy button }` (lines 229–246). Add a "Re-apply terminology" button alongside the Copy button — after the Copy button and before the closing `}` of the HStack:

```swift
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
```

- [ ] **Step 2: Add the visibility computed property**

Add to the private computed properties section of `RecordedMeetingView` (e.g. near `shouldShowPipelineBanner`):

```swift
    private var canReapplyTerminology: Bool {
        guard meeting.rawTranscript != nil else { return false }
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled) else { return false }
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        return !TerminologyService.parse(raw).isEmpty
    }
```

- [ ] **Step 3: Add the action**

Add to the private functions section (e.g. near `summarizeMeeting()` around line 446):

```swift
    private func reapplyTerminology() async {
        guard let raw = meeting.rawTranscript else { return }
        let entries = TerminologyService.parse(
            UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )
        guard !entries.isEmpty else { return }

        let corrected = await terminologyService.correct(raw, entries: entries)
        guard meeting.modelContext != nil else { return }
        meeting.transcript = corrected
        save()
    }
```

`save()` is already defined as a private helper in `RecordedMeetingView` — reuse it.

- [ ] **Step 4: Build and smoke-test**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build 2>&1 | tail -20
```

Then run the app and verify:

1. Disable terminology in Settings. Open any meeting — the "Re-apply terminology" button should be hidden.
2. Enable terminology, add `Medicore: Mediscore` to the list. Open a meeting that has `rawTranscript == nil` (a meeting transcribed before the change) — button still hidden.
3. Record a new short meeting with the toggle enabled and the list populated. After completion, change the list (e.g. add `Topdesk: Topdsk`), reopen the meeting, click "Re-apply terminology". Observe `meeting.transcript` updates.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Views/RecordedMeetingView.swift
git commit -m "feat(terminology): add re-apply action to recorded meeting view"
```

---

## Task 10: End-to-end smoke test

**Files:** None (manual verification + final commit if any tweaks).

- [ ] **Step 1: Disabled-state regression**

In Settings, ensure the terminology toggle is **off**. Record a 30-second meeting. Confirm:
- `meeting.rawTranscript` is `nil` (inspect via the SwiftData store or by exporting and checking — easiest path: add a temporary print, then remove).
- Transcript and summary are unchanged from previous behaviour.
- No additional Ollama call appears in `~/Library/Logs` or whatever console output you observe.

- [ ] **Step 2: Enabled, dictionary-only entries**

In Settings, enable the toggle and set the list to:

```
Medicore: Mediscore, MediCore, Medi-Core
Topdesk: TopDesk, Top-Desk
```

Record a short meeting where you say "Mediscore" and "TopDesk". After completion:
- `meeting.rawTranscript` contains the misspelled words.
- `meeting.transcript` contains "Medicore" and "Topdesk".
- Summary uses the canonical spellings.
- The pipeline banner briefly shows "Correcting terminology…".

- [ ] **Step 3: Enabled, with canonical-only entries**

Add `Wegiz BgZ` (no aliases) to the list. Record a meeting referencing it. Confirm Ollama still runs (banner shows correction stage) and the canonical spelling is preserved.

- [ ] **Step 4: Ollama failure path**

In Settings, change the Ollama endpoint to an invalid URL (e.g. `http://localhost:11430`). Record a short meeting with the terminology toggle on. Confirm:
- The dictionary-replaced transcript still lands in `meeting.transcript`.
- The yellow warning notice appears at the top of the transcript card.
- Dismissing the warning via the X button hides it.
- Summarization still proceeds (will likely also fail at the same endpoint — set the endpoint back to working before continuing).

- [ ] **Step 5: Re-apply on a legacy meeting**

Open any meeting transcribed before this feature was merged (or quickly delete `rawTranscript` from a meeting in the SwiftData store). Confirm the "Re-apply terminology" button is hidden.

- [ ] **Step 6: Mid-correction deletion**

Set Ollama endpoint to a slow/local large model (or insert a temporary `try? await Task.sleep(for: .seconds(20))` at the top of `runOllamaPass` to simulate latency, then remove). Start recording, stop, and while the banner shows "Correcting terminology…", delete the meeting from the sidebar. Confirm: no crash, no error dialog, no orphan transcript file. Remove any debug sleep.

- [ ] **Step 7: Non-blocking pipeline**

While correction is in flight (use the same artificial delay as Step 6), navigate to a different meeting in the sidebar. Confirm the UI stays responsive and the originating meeting still resolves correctly when correction finishes.

- [ ] **Step 8: Final cleanup commit (if any tweaks)**

If any of Steps 1–7 surfaced issues that required code changes, commit each fix with a descriptive message scoped to the issue.

---

## Branch summary commit (optional)

If this is going out as a single PR, consider an end-of-branch summary in the merge commit body. Otherwise the per-task commits above are sufficient.

---

## Spec coverage check

- ✅ New preferences (`terminologyCorrectionEnabled`, `terminologyList`) — Task 1
- ✅ `Meeting.rawTranscript` + lightweight migration note — Task 1
- ✅ `TerminologyEntry`, parse, dictionaryReplace (regex-escape, longest-first, canonical casing), formattedForPrompt — Task 2
- ✅ `correct(...)` with timeout (60s), cancellation, fallback to dictionary, never throws — Task 3
- ✅ `@MainActor`, `@Observable` state for `isCorrecting` and `warningMessage` — Tasks 2 & 3
- ✅ `AppModel` integration — Task 4
- ✅ `renderPrompt` + `summarize` + default template injection — Task 5
- ✅ Pipeline ordering (correction before `saveTranscriptLocally` / `ExportService` / summarization) — Task 6
- ✅ Mid-correction deletion guard — Task 6, Task 9, Step 6 of Task 10
- ✅ Settings UI: toggle, sheet editor with direct `@AppStorage` binding, "Done" + "Reset to Empty" inside the sheet — Task 7
- ✅ Pipeline banner extension with "Correcting terminology…" — Task 8
- ✅ Inline warning notice with dismiss action — Task 8
- ✅ Re-apply action with visibility rules — Task 9
- ✅ Non-blocking pipeline manual verification — Task 10
