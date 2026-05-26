# oMLX as an alternative local LLM provider

**Date:** 2026-05-26
**Status:** Design approved, ready for implementation plan

## Summary

Add support for [oMLX](https://github.com/jundot/omlx) as an alternative to Ollama for local LLM inference. Users pick a provider in Settings; the default remains Ollama, so existing users see no behavior change. Both summarization and terminology correction use the same selected provider.

## Motivation

oMLX is an Apple-Silicon-native MLX server with continuous batching and tiered KV caching. It is meaningfully faster than Ollama for some workloads on Mac, and some users already run it. Casablanca currently hard-codes Ollama's `/api/generate` request shape in two services, so switching providers requires code changes. This spec introduces a small abstraction so both providers — and any future OpenAI-compatible local server (LM Studio, `mlx_lm.server`, etc.) — can be selected from Settings.

## Goals

- Add oMLX as a selectable provider for summarization and terminology correction.
- Keep Ollama as the default; existing installs are unaffected.
- Confine provider-specific HTTP shape to a single file per provider.
- Per-provider endpoint and model configuration that survives switching back and forth.

## Non-goals (out of scope)

- Per-feature provider selection (summarization on one, terminology on another).
- API key / auth header support — both providers are local with no auth.
- Streaming responses.
- oMLX features Casablanca does not use today: embeddings, VLM, OCR, rerankers.
- A general "Add custom OpenAI-compatible endpoint" UI. oMLX is added as a named provider; a generic provider can be added later if needed.

## Architecture

A small protocol decouples the two call sites from the wire format.

```
LLMProvider (protocol)
  var displayName: String { get }                                          // "Ollama" or "oMLX"
  func generate(prompt: String, temperature: Double?) async throws -> String
  func fetchAvailableModels(endpoint: String) async throws -> [String]

OllamaProvider   → POST {endpoint}/api/generate           → parse `response`
OMLXProvider     → POST {endpoint}/v1/chat/completions    → parse `choices[0].message.content`

LLMProviderFactory.current() -> LLMProvider
  reads AppPreferenceKey.llmProvider, returns a fresh provider instance
  pre-wired with the active endpoint and model from UserDefaults.
  Called per request; no caching. This matches @Observable services that
  live for the app session: they call the factory each time, so a Settings
  change is picked up on the next call with no invalidation hook needed.
```

`fetchAvailableModels` is an instance method (not `static`) so it can be called through the protocol existential without `type(of:)` gymnastics. Settings view calls `LLMProviderFactory.current().fetchAvailableModels(endpoint:)` and passes the active provider's endpoint — never hardcoded to Ollama.

Files (new):
- `Casablanca/Services/LLM/LLMProvider.swift` — protocol + shared error type + factory.
- `Casablanca/Services/LLM/OllamaProvider.swift` — moves the Ollama URL building, request body, and response parsing out of `SummarizationService` / `TerminologyService`.
- `Casablanca/Services/LLM/OMLXProvider.swift` — new.

Files (changed):
- `Casablanca/Services/SummarizationService.swift` — drop `OllamaGenerateRequest/Response` structs and URL building; call the provider returned by the factory. Keep prompt rendering and `SummaryResponseParser` integration. `fetchAvailableModels(endpoint:)` becomes a thin pass-through that dispatches to the active provider's static method.
- `Casablanca/Services/TerminologyService.swift` — drop its `OllamaGenerateRequest/Response` structs and URL building; call the provider with temperature 0.
- `Casablanca/Models/Meeting.swift` — add new `AppPreferenceKey` entries (see Preferences).
- `Casablanca/Models/AppPreferences.swift` — add `LLMProviderKind` enum + typed accessors.
- `Casablanca/Views/SettingsView.swift` — rename section, add provider picker, swap endpoint/model bindings based on selection. **All "Ollama" string references must be touched**, specifically:
  - `:189` `Section("Ollama (Summarization)")` → `Section("Local LLM (Summarization)")`
  - `:223` `"Loading installed Ollama models…"` → `"Loading installed \(provider.displayName) models…"`
  - `:232` `"No Ollama models were found at this endpoint yet."` → uses `displayName`
  - `:241` `"Casablanca loads the installed models from Ollama …"` → uses `displayName`
  - `:274` (Terminology section) `"low-temperature Ollama pass"` → `"low-temperature local LLM pass"`
  - The local `@State` `availableOllamaModels` / `isLoadingOllamaModels` / `ollamaModelsError` and the `refreshOllamaModels()` helper get renamed to drop the "Ollama" prefix since they now serve either provider.
- `Casablanca/Services/AppleNotesBodyRenderer.swift:101` has a code comment "the dialect Ollama and humans commonly produce". Non-load-bearing; leave as-is (markdown output dialect is provider-independent and rewriting it adds noise).

### Error type

Define a new `LLMProviderError` in `Casablanca/Services/LLM/LLMProvider.swift` — both providers throw it. `SummarizationError` and `TerminologyService.TerminologyError` stay where they are; their call sites either propagate `LLMProviderError` directly (preferred — it conforms to `LocalizedError`) or, where the existing API surface needs to be preserved, map it into the existing case (`SummarizationError.requestFailed(error.localizedDescription)`, etc.). No types are moved.

`LLMProviderError` cases and messages (interpolating `displayName` where specificity matters):

- `invalidEndpoint` → "The {provider} endpoint is invalid. Update it in Settings."
- `requestFailed(String)` → "{provider} request failed: …" / "Could not reach {provider}: …"
- `emptyResponse` → "{provider} returned an empty summary."
- `missingSourceMaterial` stays on `SummarizationError` (it's not a provider concern).

`TerminologyService.TerminologyError` is mapped from `LLMProviderError` the same way. The `looksLikeMangledOutput` heuristic in `TerminologyService.swift:70` is provider-agnostic and stays on `TerminologyService` (not pushed into either provider).

## Preferences

Add three new keys to `AppPreferenceKey` in `Casablanca/Models/Meeting.swift`:

| Key | Type | Default |
|---|---|---|
| `llmProvider` | String (`"ollama"` \| `"omlx"`) | `"ollama"` |
| `omlxEndpoint` | String | `"http://localhost:8000/v1"` |
| `omlxModel` | String | `""` (user picks from `/v1/models`) |

Existing keys `ollamaEndpoint` and `ollamaModel` are unchanged. Each provider stores its own endpoint and model so the user can switch back and forth without clobbering the other's configuration.

Add a typed mirror in `AppPreferences.swift`:

```swift
enum LLMProviderKind: String { case ollama, omlx }

extension AppPreferences {
    static func llmProvider(in defaults: UserDefaults = .standard) -> LLMProviderKind {
        let raw = defaults.string(forKey: AppPreferenceKey.llmProvider) ?? ""
        return LLMProviderKind(rawValue: raw) ?? .ollama
    }
    static func setLLMProvider(_ value: LLMProviderKind, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppPreferenceKey.llmProvider)
    }
}
```

## Settings UI

Rename the existing `Section("Ollama (Summarization)")` to `Section("Local LLM (Summarization)")`. Add a `Picker` (segmented style) at the top:

```
Provider:   ( Ollama  |  oMLX )

Endpoint:   [http://localhost:11434                ]   ← binds to ollamaEndpoint or omlxEndpoint
Model:      [llama3.2 ▼] [Refresh]                     ← binds to ollamaModel or omlxModel

[helper text — adapts to active provider]
```

Behavior:
- The endpoint field, model picker, refresh button, loading/error state, and helper text all bind to whichever provider is selected.
- Switching providers triggers a refresh of the model list against the new endpoint.
- The "Casablanca loads the installed models from … so summarization uses a valid local model." helper text uses the active provider's display name.
- The terminology correction section's existing copy mentioning "low-temperature Ollama pass" becomes "low-temperature local LLM pass" so it stays accurate when oMLX is active.

## Provider details

### Ollama (existing behavior preserved)

Move the URL building (currently duplicated across `SummarizationService.swift:208-228` and `TerminologyService.swift:140-149`) into `OllamaProvider`. Both call sites then share one implementation.

- Generate URL — tolerate all four current forms (symmetric with oMLX list below):
  - `http://localhost:11434` → append `/api/generate`
  - `http://localhost:11434/` → append `api/generate`
  - `http://localhost:11434/api` → append `/generate`
  - `http://localhost:11434/api/generate` → use as-is
- Models URL: same ladder ending in `/api/tags`. Response: `{ "models": [{ "name": "…" }, …] }`.
- Request: `{ "model": …, "prompt": …, "stream": false, "options": { "temperature": … }? }`.
- Response: `{ "response": "…", "error": "…"? }`.

### oMLX

- Generate URL: `{endpoint}/v1/chat/completions`. Endpoint normalization tolerates:
  - `http://localhost:8000` → append `/v1/chat/completions`
  - `http://localhost:8000/` → append `v1/chat/completions`
  - `http://localhost:8000/v1` → append `/chat/completions`
  - `http://localhost:8000/v1/` → append `chat/completions`
  - `http://localhost:8000/v1/chat/completions` → use as-is
- Models URL: `{endpoint}/v1/models` (with the same normalization rules — strip trailing `/chat/completions` if present, ensure `/v1/models`). Response shape: `{ "data": [{ "id": "…" }, …] }`. Map to `[String]` of ids, sorted.
- Request body:
  ```json
  {
    "model": "<model>",
    "messages": [{"role": "user", "content": "<prompt>"}],
    "stream": false,
    "temperature": <double>            // omitted if temperature == nil
  }
  ```
- Response parsing: `choices[0].message.content`, trimmed.
  - If `choices` is empty, `content` is missing/`null` (e.g., a tool-call response), or trimmed content is empty → `emptyResponse`.
  - If the body has an `error` field or HTTP status is not 2xx → `requestFailed`.
  - If `choices[0].finish_reason == "length"` (model hit max tokens), still return the partial content — do not throw — but surface a `warningMessage` on the calling service ("Summary may be truncated: model reached its output length limit."). For terminology correction, the existing `looksLikeMangledOutput` heuristic already catches drastic truncation; no extra handling needed there.
  - Multi-choice responses (`choices.count > 1`) take `choices[0]`.
- Timeouts: same values as Ollama (120s for summarization, 60s for terminology correction).
- Default endpoint `http://localhost:8000/v1` matches the oMLX README ("Any OpenAI-compatible client can connect to `http://localhost:8000/v1`").

## Testing

New tests in `CasablancaTests/`:

- `OMLXProviderTests`
  - Endpoint normalization: all five forms above resolve to the right URL.
  - Request body shape: model, messages, stream=false, temperature included only when set.
  - Response parsing: happy path (returns trimmed content).
  - Empty `choices` array → `emptyResponse`.
  - Non-2xx status → `requestFailed` with body text included.
  - Body contains `error` field → `requestFailed`.
  - Malformed JSON → `requestFailed`.
  - `fetchAvailableModels` parses `{ "data": [{"id":…}] }` and sorts.
- `OllamaProviderTests` — backfill equivalent coverage for the existing logic since we're moving it. Same scenarios adapted to Ollama's wire format.
- `LLMProviderFactoryTests`
  - Default (no `llmProvider` key set) returns Ollama provider.
  - `llmProvider = "omlx"` returns oMLX provider.
  - Unknown raw value (`llmProvider = "garbage"`) falls back to `.ollama` — round-trip safety for `LLMProviderKind`.
  - Each returned provider reads its own endpoint and model keys.
  - Two sequential `current()` calls with a `setLLMProvider` change between them return providers of different concrete types (verifies no caching).
- `SettingsView` model-refresh behavior (lightweight ViewInspector or extracted helper test): switching the provider picker triggers a model-list refresh against the **new** provider's endpoint, not the previous one's.

`SummarizationService` and `TerminologyService` tests, if any exist, should not need to change beyond test-doubling the provider rather than the HTTP client. (Today these services don't appear to have unit tests; if so, that's pre-existing — not in scope here.)

## Migration

- New install or upgrade with no `llmProvider` key set → defaults to `.ollama`. Existing users see no behavior change.
- No data migration needed; existing `ollamaEndpoint` and `ollamaModel` keys keep working unchanged.

## Risks

- **Endpoint normalization regressions.** Both providers now have URL-tweaking logic. Mitigated by explicit unit tests covering each shape.
- **oMLX response variability.** If oMLX ever returns a multi-choice response or includes role/tool-call fields, `choices[0].message.content` parsing must still work. The test for empty `choices` covers the degenerate case; we accept normal multi-choice responses by taking the first.
- **Picker UX confusion.** A user with both servers running might wonder why models from the other show up only after switching providers. Helper text and the per-provider endpoint/model preference make the boundary clear.
