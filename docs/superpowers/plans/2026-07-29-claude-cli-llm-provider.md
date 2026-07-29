# Claude Code (`claude -p`) as a third LLM provider

Task-decomposed execution plan. Source plan: `.context/plan-claude-cli-provider.md`.

## Context

Casablanca's AI features (meeting summary, terminology correction, meeting chat, prep
"Draft with AI") all go through the `LLMProvider` protocol, currently backed by two
local providers: Ollama and oMLX. We add `claude -p` (headless Claude Code) as a third
backend so these features can use a frontier model billed against the existing Claude
subscription — no separate API key, no per-token cost.

The app is **not sandboxed** (`Casablanca/Casablanca.entitlements` has no app-sandbox
key), so spawning the `claude` CLI via `Process` works.

### Verified facts (probed on this machine, 2026-07-29 — do not re-derive)

- Installed CLI: `2.1.220`, at `~/.local/bin/claude` (a symlink to a standalone binary).
- This exact invocation works, returns in ~1.7s, one turn, no MCP servers spawned:

  ```
  echo "Reply with exactly: OK" | claude -p --output-format json --model sonnet \
    --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence \
    --system-prompt "..."
  ```

- All of `-p`, `--output-format`, `--model`, `--tools`, `--strict-mcp-config`,
  `--setting-sources`, `--no-session-persistence`, `--system-prompt` exist in 2.1.220.
  `--max-turns` does **not** exist. Do not use it.
- The success envelope is a single JSON object on stdout containing (among many other
  keys) `"is_error": false`, `"subtype": "success"`, `"result": "OK"`. Error subtypes
  such as `error_during_execution` **omit** `result` entirely.

## Global Constraints

These bind every task. A reviewer should treat a violation as a defect.

1. **Swift 6, macOS app, no new external dependencies.** Foundation only.
2. **New source files must be registered with the Xcode project** or they are not
   compiled and not run:
   `ruby scripts/add-files-to-xcodeproj.rb <path> [<path> …]`
   (paths under `CasablancaTests/` route to the test target automatically).
3. **Full test suite command** (run once before committing):

   ```bash
   xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
     -derivedDataPath .build/test -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
   ```

   For a focused loop add `-only-testing:CasablancaTests/<TestClass>`.
4. **Tests must never invoke the real `claude` binary.** Every call would bill against
   the subscription and make the suite non-hermetic. Provider tests use an injected
   fake command runner. The one exception is `ProcessCommandRunner`'s own tests, which
   use `/bin/cat`, `/bin/echo`, `/bin/sh`, `/bin/sleep`.
5. **Follow the established provider pattern**: `OllamaProvider` /
   `OMLXProvider` in `Casablanca/Services/LLM/` are the reference for struct shape,
   error construction, doc-comment density, and test style
   (`CasablancaTests/LLM/OllamaProviderTests.swift`).
6. **Out of scope, do not build:** streaming output; per-feature provider routing;
   API-key / pay-as-you-go support (deliberately subscription-only); a `--max-turns`
   guard; retries inside the provider (`LLMRetryPolicy` owns retries).
7. **The build must be green at the end of every task.** Adding a case to
   `LLMProviderKind` breaks four exhaustive switches across two views; Task 3 owns
   landing all of them together.
8. Commit on the current branch. Never commit to `master`.

---

## Task 1: `CommandRunning` seam and `ProcessCommandRunner`

Create the injectable subprocess seam that `ClaudeCLIProvider` (Task 2) runs on. This
task adds new files only and changes no existing behavior.

### Files

- **New** `Casablanca/Services/LLM/CommandRunner.swift`
- **New** `CasablancaTests/LLM/ProcessCommandRunnerTests.swift`

Register both with `ruby scripts/add-files-to-xcodeproj.rb`.

### Interface — use these names and signatures verbatim

```swift
/// The outcome of running a subprocess to completion.
struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// Why running a subprocess did not produce a `CommandResult`.
enum CommandRunError: Error, Equatable {
    /// The executable could not be launched (missing, not executable, bad path).
    case launchFailed(String)
    /// The process was still running when `timeout` elapsed, and was terminated.
    case timedOut
}

/// Runs a subprocess, feeding it `standardInput` and capturing its output.
/// Exists so `ClaudeCLIProvider` can be tested without spawning `claude`
/// (mirrors the `urlSession` injection in the HTTP-backed providers).
protocol CommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult
}

/// `CommandRunning` backed by `Foundation.Process`.
struct ProcessCommandRunner: CommandRunning { … }
```

### Behavior requirements

- **No deadlock on large I/O.** A 64 KB pipe buffer is the whole trap here: the
  transcript prompts this seam carries are ~80 KB and the echoed replies can be just as
  large. stdout and stderr must be drained concurrently with the stdin write, not after
  it. Writing all of stdin before starting to read, or reading stdout to EOF before
  reading stderr, will hang on real inputs.
- **Timeout.** If the process is still running after `timeout` seconds, terminate it and
  throw `CommandRunError.timedOut`. Do not return a partial `CommandResult`. If
  `SIGTERM` leaves it alive after a short grace period, `SIGKILL` it — never leak a
  running `claude`.
- **Cancellation.** Wrap the wait in `withTaskCancellationHandler`; on cancellation
  terminate the process and throw `CancellationError`. Cancelled runs that orphan a
  `claude` process keep burning subscription usage, so this is load-bearing, not
  hygiene.
- **Launch failure.** A missing or non-executable `executable` throws
  `CommandRunError.launchFailed` with the underlying description — it must not trap or
  crash. (`Process.run()` throws for a bad path; `NSInvalidArgumentException` is raised
  instead if `executableURL` is nil, so always set it.)
- Non-zero exit is **not** an error: return the `CommandResult` with its `exitCode`,
  stdout, and stderr. Callers decide what a non-zero exit means.
- `standardInput` is written and the pipe closed, so the child sees EOF. An empty string
  means "close stdin immediately".
- Decode stdout/stderr as UTF-8, replacing invalid sequences rather than failing.
- `workingDirectory` when non-nil sets `Process.currentDirectoryURL`.

### Tests (`ProcessCommandRunnerTests`)

These exercise the real `Process`, using system binaries — hermetic, no network, fast.

1. `/bin/echo` with `arguments: ["hi"]` → `exitCode == 0`, `standardOutput == "hi\n"`.
2. **Large round trip**: `/bin/cat` with a 300 KB `standardInput` → stdout equals the
   input exactly, exit 0. (This is the deadlock guard; it must fail if drain/write are
   serialized.)
3. `/bin/sh` with `["-c", "printf err >&2; exit 3"]` → `exitCode == 3`,
   `standardError == "err"`.
4. `/nonexistent/claude` → throws `CommandRunError.launchFailed`.
5. **Timeout**: `/bin/sleep` with `["30"]` and `timeout: 0.5` → throws
   `CommandRunError.timedOut`, and the call returns in well under 30s (assert measured
   elapsed < 10s).
6. **Cancellation**: run `/bin/sleep 30` inside a `Task`, cancel it, and assert the
   await throws (`CancellationError`) and returns in well under 30s.
7. `workingDirectory`: `/bin/pwd` with a temp directory → stdout is that directory
   (resolve symlinks before comparing; `/var` vs `/private/var` will otherwise bite).

### Notes

- `Process` is not `Sendable`; keep it local to the `run` call and use a small
  lock-protected box or an actor to accumulate the drained data.
- Keep this file focused on running commands. No `claude`-specific knowledge belongs
  here.

---

## Task 2: `ClaudeCLIProvider`

The provider itself: build the argument list, feed the prompt on stdin, parse the JSON
envelope, and map failures onto `LLMProviderError` so `LLMRetryPolicy` behaves. This
task adds new files only — it does **not** touch `LLMProviderKind` or the factory
(Task 3 does), so the build stays green.

### Files

- **New** `Casablanca/Services/LLM/ClaudeCLIProvider.swift`
- **New** `CasablancaTests/LLM/ClaudeCLIProviderTests.swift`

Register both with `ruby scripts/add-files-to-xcodeproj.rb`.

### Shape

```swift
struct ClaudeCLIProvider: LLMProvider {
    /// Path to the `claude` binary. Empty means "auto-detect". The protocol's
    /// `endpoint` carries the CLI path for this provider, because that is what
    /// `SettingsView.refreshModels` and `SummarizationService.fetchAvailableModels`
    /// thread through.
    let endpoint: String
    let model: String
    let runner: CommandRunning
    let defaults: UserDefaults

    init(endpoint: String, model: String, runner: CommandRunning = ProcessCommandRunner(),
         defaults: UserDefaults = .standard)

    var displayName: String { "Claude Code" }
}
```

### Invocation contract — these exact arguments, in this order

```swift
static let systemPrompt = """
You are a text completion assistant. Follow the user's instructions exactly and \
reply with only the requested output — no preamble, no commentary, no questions.
"""

/// The full argument list for a completion run. Exposed so a test can lock the
/// invocation contract: each flag here suppresses a Claude Code agent behavior we
/// do not want, and a silent regression would cost tokens or spawn MCP servers.
static func completionArguments(model: String) -> [String] {
    [
        "-p",
        "--output-format", "json",
        "--model", model,
        "--tools", "",              // no tools → guaranteed single completion turn
        "--strict-mcp-config",      // with no --mcp-config → zero MCP servers
        "--setting-sources", "",    // skip user CLAUDE.md / hooks / settings
        "--no-session-persistence", // don't write a session per summary
        "--system-prompt", systemPrompt,
    ]
}
```

Do **not** add `--max-turns` (absent in 2.1.220) or `--disallowedTools "*"`.

### `generate` behavior

1. Resolve the binary path (see *Path resolution*). Nil → throw
   `LLMProviderError.invalidEndpoint(provider: displayName)`.
2. **Strip a trailing `/no_think` suffix** from the prompt. Callers append it via
   `LLMPromptSupport.applyThinkingSwitch` (`SummarizationService.swift`,
   `MeetingChatService.swift`, `PrepEditorView.swift`) for local Qwen models; to Claude
   it is meaningless slash-command noise. Strip
   `LLMPromptSupport.noThinkSuffix` when it is the trailing token, then trim trailing
   whitespace. Leave a prompt that merely *contains* the string mid-text alone.
3. Create a fresh temp working directory
   (`FileManager.default.temporaryDirectory` + a UUID); remove it in a `defer`.
4. Run via `runner`, passing the prompt as `standardInput` and the caller's `timeout`.
5. `temperature` and `maxTokens` are ignored — the CLI exposes neither. Call
   `truncated?(false)`: the CLI reports no length-limit signal.

### Error mapping — evaluate in this order

`LLMProviderError.isTransient` (LLMProvider.swift:44) decides whether
`LLMRetryPolicy` reruns the call, so the `kind` on each case is the point.

| Condition | Throw | Transient? |
|---|---|---|
| `CancellationError` from the runner | rethrow unchanged | — |
| `CommandRunError.launchFailed` | `.invalidEndpoint(provider:)` | no |
| `CommandRunError.timedOut` | `.requestFailed(kind: .network(.timedOut), …)` | **yes**, by design |
| `exitCode != 0` | `.requestFailed(kind: .backendError, …)` | **no**, by design |
| exit 0, stdout not decodable as the envelope | `.requestFailed(kind: .malformedResponse, …)` | no |
| exit 0, `is_error == true` | `.requestFailed(kind: .backendError, …)` | no |
| exit 0, no error, `result` nil or blank | `.emptyResponse(provider:)` | no |
| otherwise | return `result`, trimmed | — |

Two deliberate trade-offs, both already accepted — do not "fix" them:

- `.backendError` is **non-transient on purpose**: a usage-limit hit will not resolve
  inside the retry window. The cost is that a genuinely transient API blip (529) also
  won't retry.
- Timeout is **transient on purpose**, so terminology correction's 240s × 3 attempts can
  take ~12 minutes worst case.

Message construction:

- Non-zero exit **must not require JSON** — usage-limit and bad-flag failures print plain
  text. Use whichever of stderr/stdout is non-blank (prefer stderr) as the message. If
  the stdout happens to decode and carries a `result`, that is fine to prefer, but a
  non-JSON body must still produce a useful message.
- `is_error == true` may arrive **without a `result` key**: decode `result` as optional
  and fall back to `subtype`, then stderr, then a generic sentence. Never
  force-unwrap.

Envelope (only the keys we need; the real payload has ~20 more — ignore them):

```swift
private struct ResultEnvelope: Decodable {
    let result: String?
    let subtype: String?
    let isError: Bool?
    enum CodingKeys: String, CodingKey { case result, subtype, isError = "is_error" }
}
```

### Path resolution

```swift
/// Where the native installer and the common package managers put `claude`,
/// in the order we trust them.
static let candidatePaths: [String]
```

- `~/.local/bin/claude` (native-installer default; where it lives on this machine)
- `~/.claude/local/claude`
- `/opt/homebrew/bin/claude`
- `/usr/local/bin/claude`

Resolution: a non-blank `endpoint` (trimmed) wins outright — a bogus one surfaces as
`.invalidEndpoint` via `launchFailed`, which is the correct, visible failure. Otherwise
return the first candidate that `FileManager.isExecutableFile(atPath:)` accepts.
Otherwise fall back to `which claude` **through `runner`** using a login shell
(`/bin/zsh` with `["-lc", "command -v claude"]`, short timeout), taking the first
non-blank output line if it exits 0. A GUI-spawned `Process` inherits a minimal PATH,
which is why the login shell is needed at all — and also why
`~/.claude/local/claude` (a `#!/usr/bin/env node` wrapper) is ranked below the
standalone binary: without `node` on PATH it cannot run.

### `fetchAvailableModels(endpoint:)`

The CLI has no model-list command, so this doubles as the reachability probe that
Settings and Onboarding show.

1. Resolve the path from the passed `endpoint` (same rules as above; the argument wins
   over the stored property, matching how `refreshModels` calls it). Nil →
   `.invalidEndpoint(provider:)`.
2. Run `[--version]` with empty stdin and a short timeout (10s).
   `launchFailed` → `.invalidEndpoint(provider:)`; non-zero exit →
   `.requestFailed(kind: .backendError, …)` carrying the output, so Settings shows
   something actionable.
3. On success, if the resolved path differs from what is stored under
   `AppPreferenceKey.claudeCLIPath`, **write it back to `defaults`** — that is what
   makes the auto-detected path appear in the Settings / Onboarding field.
4. Return `["haiku", "opus", "sonnet"]` (the protocol documents ascending order).
   Expose it as `static let availableModels` so the test and the factory's default can
   refer to one list.

### Tests (`ClaudeCLIProviderTests`)

Use a `FakeCommandRunner: CommandRunning` that records the last call
(`executable`, `arguments`, `standardInput`, `workingDirectory`, `timeout`) and returns
a canned `CommandResult` or throws a canned error. It must satisfy `Sendable` — a
lock-protected box or an actor with async accessors, not a bare `var`.

1. Success: envelope with `"result": "Summary text"` → returns `"Summary text"`, and the
   `truncated` closure is called with `false`.
2. `is_error: true` **with no `result` key** and exit 0 → `.requestFailed`, kind
   `.backendError`, and assert `isTransient == false`.
3. Non-JSON stdout with exit 0 → kind `.malformedResponse`.
4. Non-zero exit with plain-text stderr (`"Claude usage limit reached"`) → kind
   `.backendError`, message contains that text, `isTransient == false`.
5. Runner throws `.launchFailed` → `.invalidEndpoint`.
6. Runner throws `.timedOut` → kind `.network(.timedOut)`, and assert
   `isTransient == true`.
7. Runner throws `CancellationError` → provider rethrows `CancellationError` (does not
   convert it into a provider error, which would make the retry policy rerun a
   cancelled call).
8. stdin carries the prompt verbatim.
9. A prompt ending in `"\n\n/no_think"` reaches the CLI with that suffix removed.
10. Argument contract: the recorded arguments contain `-p`, the `--model` pair for the
    configured model, and each of `--tools ""`, `--strict-mcp-config`,
    `--setting-sources ""`, `--no-session-persistence` as adjacent flag/value pairs.
11. Exit 0 with `"result": "   "` → `.emptyResponse`.
12. `workingDirectory` passed to the runner is non-nil and exists at call time.
13. `fetchAvailableModels` with a `--version`-style success → equals
    `ClaudeCLIProvider.availableModels`, and the recorded arguments are `["--version"]`.
14. `fetchAvailableModels` writes the resolved path into an injected
    `UserDefaults` suite under `AppPreferenceKey.claudeCLIPath`. (This key lands in
    Task 3 — if it does not exist yet, add it there and note the ordering; do not
    hardcode the string literal in the provider.)
15. `fetchAvailableModels` when the runner reports `launchFailed` → `.invalidEndpoint`.

Assert on the error `kind`, not on message text, except where a test explicitly checks
that a plain-text failure reaches the user (case 4).

### Note on ordering with Task 3

`AppPreferenceKey.claudeCLIPath` and `.claudeCLIModel` are Task 3's changes, but this
task needs the path key. Add **only those two key constants** here if that is simpler
than blocking; adding a key constant breaks no switch. Do not add
`LLMProviderKind.claudeCode` in this task — that is what cascades into the views.

---

## Task 3: Preference keys, provider kind, factory wire-up

Make the new provider selectable. Adding a `LLMProviderKind` case breaks four
exhaustive switches across two views; this task lands all of them so the build is green,
with the *minimum* UI change needed. Copy and layout polish is Tasks 4 and 5 — do not do
it here.

### Files

- `Casablanca/Models/Meeting.swift` — `AppPreferenceKey` (top of file, ~lines 4–38)
- `Casablanca/Models/AppPreferences.swift` — `LLMProviderKind` (~line 13)
- `Casablanca/Services/LLM/LLMProvider.swift` — `LLMProviderFactory.current()` (~line 95)
- `Casablanca/Views/SettingsView.swift` — `@AppStorage` block (~lines 15–20) and the
  three switches `providerEndpointBinding` / `providerModelBinding` /
  `providerDisplayName` (~lines 60–78)
- `Casablanca/Views/OnboardingView.swift` — `@AppStorage` block (~lines 20–23) and the
  two switches `providerDisplayName` / `providerEndpoint` (~lines 52–64)
- `CasablancaTests/AppPreferencesTests.swift`
- `CasablancaTests/LLM/LLMProviderFactoryTests.swift`

### Changes

1. `AppPreferenceKey`: add `claudeCLIPath = "claudeCLIPath"` and
   `claudeCLIModel = "claudeCLIModel"` (skip if Task 2 already added them).
2. `LLMProviderKind`: add `case claudeCode` (raw value `"claudeCode"`). The
   unknown-raw-value fallback to `.ollama` in `AppPreferences.llmProvider` already makes
   this persistence-safe in both directions.
3. `LLMProviderFactory.current()`: add the `.claudeCode` case.
   - `endpoint` ← `AppPreferenceKey.claudeCLIPath`, defaulting to `""` (empty means
     auto-detect).
   - `model` ← `AppPreferenceKey.claudeCLIModel`, defaulting to `"sonnet"` — and treat a
     **stored-but-empty** value as absent too, so a blank pref can't ship `--model ""`
     to the CLI.
   - `runner`: `ProcessCommandRunner()`.
   - `defaults`: the `defaults` parameter, so the write-back in `fetchAvailableModels`
     lands in the same suite tests use.
   - `enableThinking` does not apply to this provider; do not thread it in.
4. `SettingsView`: add `@AppStorage` for `claudeCLIPath` (default `""`) and
   `claudeCLIModel` (default `"sonnet"`), and extend the three switches to bind them.
   `providerDisplayName` returns `"Claude Code"`.
5. `OnboardingView`: add `@AppStorage` for `claudeCLIPath` (default `""`), and extend
   `providerDisplayName` → `"Claude Code"` and `providerEndpoint` → `claudeCLIPath`.
   `runLLMCheck` already passes `providerEndpoint` into
   `SummarizationService.fetchAvailableModels`, so extending `providerEndpoint` is all
   the threading it needs — verify that, and do not add a parallel path.

No provider picker is added to Onboarding, and no copy changes belong in this task.

### Tests

In `AppPreferencesTests`, alongside the existing `testLLMProviderFallsBackOnUnknownValue`:

- `AppPreferences.llmProvider` reads `"claudeCode"` → `.claudeCode`.
- `setLLMProvider(.claudeCode)` writes the raw value `"claudeCode"`.

In `LLMProviderFactoryTests`, mirroring the existing oMLX tests:

- `.claudeCode` selected → `LLMProviderFactory.current` returns a `ClaudeCLIProvider`.
- It reads `claudeCLIPath` and `claudeCLIModel` into `endpoint` / `model`.
- With no `claudeCLIModel` set, `model == "sonnet"`.
- With `claudeCLIModel` set to `""`, `model == "sonnet"` (the empty-value guard).

---

## Task 4: Provider-aware copy, and the Settings UI

Today's AI settings copy hardcodes the assumption that the model is local — "Local LLM",
"installed models", "not installed at this endpoint", "a valid local model". With Claude
Code selected, all of it is wrong. Extract the strings that vary by provider into one
testable place, then wire Settings to it and add the third picker segment.

### Files

- **New** `Casablanca/Services/LLM/LLMProviderCopy.swift`
- **New** `CasablancaTests/LLM/LLMProviderCopyTests.swift`
- `Casablanca/Views/SettingsView.swift` — `aiSettings` (~lines 233–305), and delete the
  now-redundant local `providerDisplayName` switch in favor of the shared one

Register the new files with `ruby scripts/add-files-to-xcodeproj.rb`.

### `LLMProviderCopy`

One `enum` of static functions over `LLMProviderKind`. It exists because two views need
the same provider-conditional wording and because SwiftUI body strings are otherwise
untestable — not as a general-purpose localization layer. Add only the entries listed
here.

```swift
enum LLMProviderCopy {
    static func displayName(for: LLMProviderKind) -> String
    /// Label for the field holding the endpoint URL, or the CLI path.
    static func locationFieldLabel(for: LLMProviderKind) -> String
    /// Shown while the model list loads.
    static func modelLoadingLabel(for: LLMProviderKind) -> String
    /// Shown when the lookup succeeded but returned nothing.
    static func noModelsFound(for: LLMProviderKind) -> String
    /// Shown when the configured model isn't among the ones found.
    static func modelNotAvailable(for: LLMProviderKind) -> String
    /// Footer explaining where summarization runs.
    static func summarizationFooter(for: LLMProviderKind) -> String
    /// Provider-specific caveats; empty when there are none.
    static func caveats(for: LLMProviderKind) -> String
    /// Onboarding step 1 privacy line.
    static func privacySubtitle(for: LLMProviderKind) -> String
    /// Onboarding step 1 "summaries" feature row.
    static func summariesFeature(for: LLMProviderKind) -> (title: String, subtitle: String)
    /// Onboarding step 4 header.
    static func llmStepHeader(for: LLMProviderKind) -> (title: String, subtitle: String)
}
```

`displayName` must return exactly `"Ollama"`, `"oMLX"`, `"Claude Code"` — the same
strings the corresponding `LLMProvider.displayName` returns, because these appear in the
same UI as provider error messages and a mismatch reads as a bug.

Wording for `.claudeCode` (the local providers keep today's text unless noted):

- `locationFieldLabel`: `"CLI path"` (`"Endpoint"` for the local providers)
- `modelLoadingLabel`: `"Checking the Claude Code CLI…"`
- `noModelsFound`: `"Casablanca could not reach the Claude Code CLI. Check the path above."`
- `modelNotAvailable`: `"That model isn't one Claude Code offers. Pick one of the models above."`
- `summarizationFooter`: `"Casablanca runs the Claude Code CLI in headless mode, so summaries are drafted by Claude rather than a model on this Mac."`
- `caveats`: `"Usage counts against your Claude subscription's limits, not an API key, and each call is slower than a local model. Keep terminology correction off with Claude Code: it sends the whole transcript and expects the full text back, and a shortened reply can be saved over your transcript."`
  (Empty string for the local providers.)
- `privacySubtitle` / `summariesFeature` / `llmStepHeader`: Task 5 consumes these; define
  them here. For local providers keep today's onboarding wording verbatim
  (`OnboardingView.swift` ~lines 151–157 and ~388–390). For `.claudeCode`, the honest
  version: recording and transcription still run on the Mac, but transcripts are sent to
  Anthropic for summarization, and step 4 is about the CLI rather than a local endpoint.

Follow `medicore-technical-writing`-style plain, direct prose: no exclamation marks, no
marketing tone, sentence case.

### SettingsView wiring

- Third picker segment: `Text("Claude Code").tag(LLMProviderKind.claudeCode.rawValue)`.
  The existing `.onChange(of: llmProviderRaw)` already re-runs `refreshModels()`.
- Section header `"Local LLM (Summarization)"` → `"Language Model (Summarization)"`
  unconditionally. One always-accurate header beats a header that changes under the
  user's cursor.
- The endpoint `TextField` label comes from `locationFieldLabel`.
- Replace the four hardcoded captions with the `LLMProviderCopy` equivalents:
  the loading label, the no-models line, the model-mismatch line, and the footer.
- Render `caveats(for:)` as an additional caption below the footer when non-empty.
- The `SecureField("API key")` block stays conditional on `.omlx` — Claude Code gets no
  API-key field.
- Delete `SettingsView.providerDisplayName` and call
  `LLMProviderCopy.displayName(for: llmProvider)` instead, including at its other use
  site in `summaryPromptSheet` (~line 537).

Keep `aiSettings` readable: if a caption needs branching, put it behind a small private
computed property rather than inlining ternaries in the view body.

### Tests (`LLMProviderCopyTests`)

- Every function returns a non-empty string for all three kinds (except `caveats`, which
  is expected empty for the two local providers and non-empty for `.claudeCode`).
- `locationFieldLabel` is `"CLI path"` for `.claudeCode` and `"Endpoint"` for both local
  providers.
- **Agreement test**: for each `LLMProviderKind`, build the provider via
  `LLMProviderFactory.current(defaults:)` on a fresh suite with that kind selected, and
  assert `provider.displayName == LLMProviderCopy.displayName(for: kind)`. This is the
  guard that keeps the two intentionally-parallel copies of the name from drifting.
- `.claudeCode` copy does not claim locality: assert `summarizationFooter` and
  `privacySubtitle` for `.claudeCode` contain neither `"local"` nor `"Nothing is sent to
  the cloud"` (case-insensitive).

---

## Task 5: Onboarding copy

Step 1 currently promises "Everything stays on your Mac … Nothing is sent to the cloud"
and "A local LLM drafts your notes", and step 4 says "Connect your local LLM". With
Claude Code selected these are false. Condition them on the selected provider using the
`LLMProviderCopy` entries Task 4 defined.

### Files

- `Casablanca/Views/OnboardingView.swift` — `welcomeStep` (~lines 146–160), `llmStep`
  (~lines 385–397), and the local `providerDisplayName` switch (~lines 52–56)

### Changes

- `welcomeStep`: the `stepHeader` subtitle comes from
  `LLMProviderCopy.privacySubtitle(for: llmProvider)`; the third `featureRow`'s title
  and subtitle come from `LLMProviderCopy.summariesFeature(for: llmProvider)`. The
  "Record meetings" and "Local transcription" rows are unchanged and stay accurate —
  transcription really is on-device regardless of provider.
- `llmStep`: title and subtitle from `LLMProviderCopy.llmStepHeader(for: llmProvider)`;
  the `infoRow` label `"Endpoint"` becomes
  `LLMProviderCopy.locationFieldLabel(for: llmProvider)`.
- Delete `OnboardingView.providerDisplayName` and use
  `LLMProviderCopy.displayName(for: llmProvider)` at its use sites.
- The step-1 view is rendered before the user reaches the provider step, so it must read
  correctly for whatever provider is *currently* stored, including the `.ollama` default
  on a first run.

No new tests: the strings and their guards live in `LLMProviderCopyTests` from Task 4.
Confirm the full suite still passes and that no `providerDisplayName` switch remains in
either view (`grep -rn "providerDisplayName" Casablanca/`).
