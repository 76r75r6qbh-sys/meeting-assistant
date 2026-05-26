# oMLX LLM Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add [oMLX](https://github.com/jundot/omlx) as a selectable local LLM provider alongside Ollama, with Ollama remaining the default. Spec: `docs/superpowers/specs/2026-05-26-omlx-llm-provider-design.md`.

**Architecture:** Introduce a `LLMProvider` protocol with two implementations (`OllamaProvider`, `OMLXProvider`) and a `LLMProviderFactory` that reads `AppPreferenceKey.llmProvider` and returns a fresh provider per call. `SummarizationService` and `TerminologyService` delegate generation and model listing to the factory's provider. Each provider stores its own endpoint and model in `UserDefaults` so switching back and forth does not clobber config.

**Tech Stack:** Swift 5.10+, SwiftUI, SwiftData, XCTest, Apple's `URLSession` and `URLProtocol` for HTTP and HTTP test doubles. macOS app target.

---

## File Structure

**New files (Casablanca target):**
- `Casablanca/Services/LLM/LLMProvider.swift` — protocol, `LLMProviderError`, `LLMProviderFactory`, the `LLMProviderKind` enum's helpers.
- `Casablanca/Services/LLM/OllamaProvider.swift` — Ollama implementation (moves URL building + request/response shape out of the two services).
- `Casablanca/Services/LLM/OMLXProvider.swift` — oMLX (OpenAI-compatible) implementation.

**New files (CasablancaTests target):**
- `CasablancaTests/LLM/MockURLProtocol.swift` — shared `URLProtocol` subclass for stubbing HTTP responses in provider tests.
- `CasablancaTests/LLM/OllamaProviderTests.swift`
- `CasablancaTests/LLM/OMLXProviderTests.swift`
- `CasablancaTests/LLM/LLMProviderFactoryTests.swift`
- `CasablancaTests/LLM/LLMProviderKindTests.swift`

**Modified files:**
- `Casablanca/Models/Meeting.swift` — add three new `AppPreferenceKey` entries.
- `Casablanca/Models/AppPreferences.swift` — add `LLMProviderKind` enum and accessors.
- `Casablanca/Services/SummarizationService.swift` — delegate to provider; drop `OllamaGenerateRequest`/`OllamaGenerateResponse`/`OllamaTagsResponse`/`makeGenerateURL`/`makeURL`.
- `Casablanca/Services/TerminologyService.swift` — delegate to provider; drop `OllamaGenerateRequest`/`OllamaGenerateResponse`/`makeGenerateURL`.
- `Casablanca/Views/SettingsView.swift` — add provider picker, rename state, swap bindings.
- `CasablancaTests/AppPreferencesTests.swift` — add `LLMProviderKind` round-trip tests.

**Important:** Every new Swift file must be added to its Xcode target via `scripts/add-to-xcode.rb` before the next build/test step. The script is idempotent.

---

## Task 1: Add preference keys

**Files:**
- Modify: `Casablanca/Models/Meeting.swift:4-22`

- [ ] **Step 1: Add the three new keys**

Open `Casablanca/Models/Meeting.swift`. In the `AppPreferenceKey` enum, add these three lines after `static let terminologyList = "terminologyList"` (line 19), keeping alphabetical/logical grouping near the existing ollama keys is fine — drop them right after `ollamaModel`:

```swift
    static let llmProvider = "llmProvider"
    static let omlxEndpoint = "omlxEndpoint"
    static let omlxModel = "omlxModel"
```

- [ ] **Step 2: Build to confirm no syntax error**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/Models/Meeting.swift
git commit -m "feat(prefs): add llmProvider/omlxEndpoint/omlxModel keys"
```

---

## Task 2: Add LLMProviderKind enum and accessor

**Files:**
- Modify: `Casablanca/Models/AppPreferences.swift`
- Test: `CasablancaTests/AppPreferencesTests.swift`

- [ ] **Step 1: Write failing tests**

Append these tests to `CasablancaTests/AppPreferencesTests.swift` (before the final closing `}`):

```swift
    func testLLMProviderDefaultsToOllama() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.llmProvider(in: defaults), .ollama)
    }

    func testLLMProviderReadsStoredValue() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        XCTAssertEqual(AppPreferences.llmProvider(in: defaults), .omlx)
    }

    func testLLMProviderFallsBackOnUnknownValue() {
        let defaults = makeDefaults()
        defaults.set("garbage", forKey: AppPreferenceKey.llmProvider)
        XCTAssertEqual(AppPreferences.llmProvider(in: defaults), .ollama)
    }

    func testSetLLMProviderWritesRawValue() {
        let defaults = makeDefaults()
        AppPreferences.setLLMProvider(.omlx, in: defaults)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.llmProvider), "omlx")
    }
```

- [ ] **Step 2: Run tests to confirm they fail**

Run:
```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/AppPreferencesTests
```
Expected: 4 new tests fail with "cannot find 'AppPreferences.llmProvider' / '.omlx' in scope".

- [ ] **Step 3: Add the enum and accessors**

In `Casablanca/Models/AppPreferences.swift`, add this enum after `PrepTodoStorage` (line 11):

```swift
enum LLMProviderKind: String {
    case ollama
    case omlx
}
```

Inside the `enum AppPreferences` block, add these two static functions after `setPrepTodoStorage` (around line 30):

```swift
    static func llmProvider(in defaults: UserDefaults = .standard) -> LLMProviderKind {
        let raw = defaults.string(forKey: AppPreferenceKey.llmProvider) ?? ""
        return LLMProviderKind(rawValue: raw) ?? .ollama
    }

    static func setLLMProvider(_ value: LLMProviderKind, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppPreferenceKey.llmProvider)
    }
```

- [ ] **Step 4: Run tests to confirm they pass**

Run the same command from Step 2.
Expected: all `AppPreferencesTests` pass (including the 4 new ones).

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Models/AppPreferences.swift CasablancaTests/AppPreferencesTests.swift
git commit -m "feat(prefs): add LLMProviderKind enum and accessors"
```

---

## Task 3: Add MockURLProtocol test helper

**Files:**
- Create: `CasablancaTests/LLM/MockURLProtocol.swift`

- [ ] **Step 1: Create the directory and file**

Run: `mkdir -p CasablancaTests/LLM`

Create `CasablancaTests/LLM/MockURLProtocol.swift`:

```swift
import Foundation

/// URLProtocol stub for provider tests. Each test sets `requestHandler` to a
/// closure that returns a `(HTTPURLResponse, Data)` tuple for the incoming
/// `URLRequest`. The protocol is wired up via a custom `URLSessionConfiguration`.
final class MockURLProtocol: URLProtocol {
    /// Set per-test before issuing the request. Cleared in `tearDown`.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Captures the most recent request for assertion in tests.
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLProtocol doesn't expose `httpBodyStream` decoded body for us; tests can
        // assert against `httpBody` only when the client set it directly. URLSession
        // converts `httpBody` to a stream — we re-read it here.
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        lastRequest = nil
        lastBody = nil
    }

    /// Returns a URLSession with this protocol registered first.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 2: Register file with Xcode**

Run: `scripts/add-to-xcode.rb CasablancaTests CasablancaTests/LLM/MockURLProtocol.swift`
Expected: "Added file: CasablancaTests/LLM/MockURLProtocol.swift" (or "already in project").

- [ ] **Step 3: Build the test target**

Run:
```bash
xcodebuild build-for-testing -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add CasablancaTests/LLM/MockURLProtocol.swift Casablanca.xcodeproj
git commit -m "test: add MockURLProtocol helper for HTTP stubbing"
```

---

## Task 4: Define LLMProvider protocol, error type, and provider kind plumbing

**Files:**
- Create: `Casablanca/Services/LLM/LLMProvider.swift`

- [ ] **Step 1: Create the directory and file**

Run: `mkdir -p Casablanca/Services/LLM`

Create `Casablanca/Services/LLM/LLMProvider.swift`:

```swift
import Foundation

enum LLMProviderError: LocalizedError {
    case invalidEndpoint(provider: String)
    case requestFailed(provider: String, message: String)
    case emptyResponse(provider: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let provider):
            return "The \(provider) endpoint is invalid. Update it in Settings."
        case .requestFailed(_, let message):
            return message
        case .emptyResponse(let provider):
            return "\(provider) returned an empty response."
        }
    }
}

/// Local LLM provider. Implementations encapsulate the wire format and URL
/// construction for one backend. Created fresh per call via
/// `LLMProviderFactory.current()`.
protocol LLMProvider {
    /// Human-readable name used in user-facing error messages and the Settings UI.
    var displayName: String { get }

    /// Generate a single response for the given prompt.
    /// - Parameters:
    ///   - prompt: The full prompt text.
    ///   - temperature: Sampling temperature. `nil` means leave the model default.
    ///   - timeout: Request timeout in seconds.
    /// Returns: Trimmed response text, never empty (throws `.emptyResponse` instead).
    /// Sets `truncated` to `true` on the closure when the backend reports the
    /// output hit its length limit, so callers can surface a warning.
    func generate(
        prompt: String,
        temperature: Double?,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String

    /// List models installed on the given endpoint, sorted ascending.
    func fetchAvailableModels(endpoint: String) async throws -> [String]
}

enum LLMProviderFactory {
    /// Returns a fresh provider instance configured from the user's current
    /// preferences. Called per-request; no caching. A `urlSession` may be
    /// injected for tests; production callers omit it.
    static func current(
        defaults: UserDefaults = .standard,
        urlSession: URLSession = .shared
    ) -> LLMProvider {
        switch AppPreferences.llmProvider(in: defaults) {
        case .ollama:
            return OllamaProvider(
                endpoint: defaults.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434",
                model: defaults.string(forKey: AppPreferenceKey.ollamaModel) ?? "llama3.2",
                urlSession: urlSession
            )
        case .omlx:
            return OMLXProvider(
                endpoint: defaults.string(forKey: AppPreferenceKey.omlxEndpoint) ?? "http://localhost:8000/v1",
                model: defaults.string(forKey: AppPreferenceKey.omlxModel) ?? "",
                urlSession: urlSession
            )
        }
    }
}
```

Note the file references `OllamaProvider` and `OMLXProvider` which the next tasks add — the project won't compile yet. That's expected; we'll get the test target building once both providers exist.

- [ ] **Step 2: Register with Xcode**

Run: `scripts/add-to-xcode.rb Casablanca Casablanca/Services/LLM/LLMProvider.swift`

- [ ] **Step 3: Do NOT build yet — proceed to Task 5**

The project intentionally won't compile until both providers are added. Skip the build step and commit at the end of Task 6.

---

## Task 5: Implement OllamaProvider (with tests)

**Files:**
- Create: `Casablanca/Services/LLM/OllamaProvider.swift`
- Create: `CasablancaTests/LLM/OllamaProviderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `CasablancaTests/LLM/OllamaProviderTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class OllamaProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Endpoint normalization for generate

    func testGenerateAppendsApiGenerateToBareHost() async throws {
        try await assertGenerateURL("http://localhost:11434", expected: "http://localhost:11434/api/generate")
    }

    func testGenerateAppendsApiGenerateWithTrailingSlash() async throws {
        try await assertGenerateURL("http://localhost:11434/", expected: "http://localhost:11434/api/generate")
    }

    func testGenerateAppendsGenerateToApiSuffix() async throws {
        try await assertGenerateURL("http://localhost:11434/api", expected: "http://localhost:11434/api/generate")
    }

    func testGenerateUsesFullPathAsIs() async throws {
        try await assertGenerateURL("http://localhost:11434/api/generate", expected: "http://localhost:11434/api/generate")
    }

    private func assertGenerateURL(_ endpoint: String, expected: String) async throws {
        MockURLProtocol.requestHandler = { _ in
            (Self.okResponse(url: expected), Self.encode(["response": "hi"]))
        }
        let provider = OllamaProvider(endpoint: endpoint, model: "m", urlSession: MockURLProtocol.makeSession())
        _ = try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, expected)
    }

    // MARK: - Request body

    func testGenerateBodyOmitsTemperatureWhenNil() async throws {
        MockURLProtocol.requestHandler = { _ in
            (Self.okResponse(), Self.encode(["response": "ok"]))
        }
        let provider = OllamaProvider(endpoint: "http://x", model: "llama3.2", urlSession: MockURLProtocol.makeSession())
        _ = try await provider.generate(prompt: "hello", temperature: nil, timeout: 10, truncated: nil)
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "llama3.2")
        XCTAssertEqual(json["prompt"] as? String, "hello")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertNil(json["options"])
    }

    func testGenerateBodyIncludesTemperatureWhenSet() async throws {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Self.encode(["response": "ok"])) }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        _ = try await provider.generate(prompt: "p", temperature: 0, timeout: 10, truncated: nil)
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["temperature"] as? Double, 0)
    }

    // MARK: - Response parsing

    func testGenerateReturnsTrimmedResponse() async throws {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Self.encode(["response": "  hi  "])) }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        let result = try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)
        XCTAssertEqual(result, "hi")
    }

    func testGenerateThrowsEmptyResponseOnBlankBody() async {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Self.encode(["response": "   "])) }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.emptyResponse = error else { return XCTFail("expected emptyResponse, got \(error)") }
        }
    }

    func testGenerateThrowsRequestFailedOnErrorField() async {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Self.encode(["error": "boom"])) }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.requestFailed(_, let msg) = error else { return XCTFail("expected requestFailed, got \(error)") }
            XCTAssertTrue(msg.contains("boom"))
        }
    }

    func testGenerateThrowsRequestFailedOnNon2xx() async {
        MockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "http://x/api/generate")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data("server error".utf8))
        }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.requestFailed = error else { return XCTFail("expected requestFailed, got \(error)") }
        }
    }

    // MARK: - fetchAvailableModels

    func testFetchAvailableModelsParsesAndSorts() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/api/tags")
            let body = try JSONSerialization.data(withJSONObject: [
                "models": [["name": "zeta"], ["name": "alpha"]]
            ])
            return (Self.okResponse(url: "http://localhost:11434/api/tags"), body)
        }
        let provider = OllamaProvider(endpoint: "http://localhost:11434", model: "m", urlSession: MockURLProtocol.makeSession())
        let result = try await provider.fetchAvailableModels(endpoint: "http://localhost:11434")
        XCTAssertEqual(result, ["alpha", "zeta"])
    }

    func testDisplayNameIsOllama() {
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(provider.displayName, "Ollama")
    }

    // MARK: - Helpers

    private static func okResponse(url: String = "http://x/api/generate") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }
}

/// XCTest helper to assert an async throwing expression throws and inspect the error.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected throw, got success. \(message())", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
```

- [ ] **Step 2: Register the test file with Xcode**

Run: `scripts/add-to-xcode.rb CasablancaTests CasablancaTests/LLM/OllamaProviderTests.swift`

- [ ] **Step 3: Create the provider**

Create `Casablanca/Services/LLM/OllamaProvider.swift`:

```swift
import Foundation

struct OllamaProvider: LLMProvider {
    let endpoint: String
    let model: String
    let urlSession: URLSession

    var displayName: String { "Ollama" }

    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let options: Options?
        struct Options: Encodable { let temperature: Double }
    }

    private struct GenerateResponse: Decodable {
        let response: String?
        let error: String?
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    func generate(
        prompt: String,
        temperature: Double?,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String {
        guard let url = Self.url(forEndpoint: endpoint, suffix: "/api/generate", terminalSegment: "generate") else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(
            GenerateRequest(
                model: model,
                prompt: prompt,
                stream: false,
                options: temperature.map { GenerateRequest.Options(temperature: $0) }
            )
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: "Could not reach \(displayName): \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.requestFailed(provider: displayName, message: "\(displayName) returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: body.isEmpty
                    ? "\(displayName) request failed with status \(http.statusCode)."
                    : "\(displayName) request failed: \(body)"
            )
        }

        let payload = try JSONDecoder().decode(GenerateResponse.self, from: data)
        if let err = payload.error, !err.isEmpty {
            throw LLMProviderError.requestFailed(provider: displayName, message: "\(displayName) returned an error: \(err)")
        }

        let text = payload.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw LLMProviderError.emptyResponse(provider: displayName)
        }
        truncated?(false)  // Ollama /generate doesn't surface a length-truncation flag in non-streaming mode.
        return text
    }

    func fetchAvailableModels(endpoint: String) async throws -> [String] {
        guard let url = Self.url(forEndpoint: endpoint, suffix: "/api/tags", terminalSegment: "tags") else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: "Could not reach \(displayName): \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = (response as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "unknown"
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: "\(displayName) model lookup failed with status \(body)."
            )
        }

        let payload = try JSONDecoder().decode(TagsResponse.self, from: data)
        return payload.models.map(\.name).sorted()
    }

    /// Normalize the user-supplied endpoint into a fully-qualified URL ending in
    /// `suffix` (e.g. `/api/generate`). Tolerates: bare host, trailing slash,
    /// `/api` suffix, and the full suffix already present.
    private static func url(forEndpoint endpoint: String, suffix: String, terminalSegment: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix(suffix) { return URL(string: trimmed) }
        if trimmed.hasSuffix("/api") { return URL(string: "\(trimmed)/\(terminalSegment)") }
        if trimmed.hasSuffix("/") { return URL(string: "\(trimmed)api/\(terminalSegment)") }
        return URL(string: "\(trimmed)/api/\(terminalSegment)")
    }
}
```

- [ ] **Step 4: Register the provider with Xcode**

Run: `scripts/add-to-xcode.rb Casablanca Casablanca/Services/LLM/OllamaProvider.swift`

- [ ] **Step 5: Do NOT build yet**

The factory still references `OMLXProvider`. Proceed to Task 6.

---

## Task 6: Implement OMLXProvider (with tests)

**Files:**
- Create: `Casablanca/Services/LLM/OMLXProvider.swift`
- Create: `CasablancaTests/LLM/OMLXProviderTests.swift`

- [ ] **Step 1: Write failing tests**

Create `CasablancaTests/LLM/OMLXProviderTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class OMLXProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Endpoint normalization for generate

    func testGenerateAppendsV1ChatCompletionsToBareHost() async throws {
        try await assertGenerateURL("http://localhost:8000", expected: "http://localhost:8000/v1/chat/completions")
    }

    func testGenerateAppendsToHostWithTrailingSlash() async throws {
        try await assertGenerateURL("http://localhost:8000/", expected: "http://localhost:8000/v1/chat/completions")
    }

    func testGenerateAppendsToV1Suffix() async throws {
        try await assertGenerateURL("http://localhost:8000/v1", expected: "http://localhost:8000/v1/chat/completions")
    }

    func testGenerateAppendsToV1TrailingSlash() async throws {
        try await assertGenerateURL("http://localhost:8000/v1/", expected: "http://localhost:8000/v1/chat/completions")
    }

    func testGenerateUsesFullPathAsIs() async throws {
        try await assertGenerateURL("http://localhost:8000/v1/chat/completions", expected: "http://localhost:8000/v1/chat/completions")
    }

    private func assertGenerateURL(_ endpoint: String, expected: String) async throws {
        MockURLProtocol.requestHandler = { _ in
            (Self.okResponse(url: expected), Self.completionsBody(content: "hi"))
        }
        let provider = OMLXProvider(endpoint: endpoint, model: "m", urlSession: MockURLProtocol.makeSession())
        _ = try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, expected)
    }

    // MARK: - Request body

    func testGenerateBodyShape() async throws {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Self.completionsBody(content: "ok")) }
        let provider = OMLXProvider(endpoint: "http://x", model: "qwen", urlSession: MockURLProtocol.makeSession())
        _ = try await provider.generate(prompt: "hello", temperature: 0.7, timeout: 10, truncated: nil)
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "qwen")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["temperature"] as? Double, 0.7)

        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertEqual(messages[0]["content"], "hello")
    }

    func testGenerateBodyOmitsTemperatureWhenNil() async throws {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Self.completionsBody(content: "ok")) }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        _ = try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["temperature"])
    }

    // MARK: - Response parsing

    func testGenerateReturnsTrimmedContent() async throws {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Self.completionsBody(content: "  hello world  ")) }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        let result = try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)
        XCTAssertEqual(result, "hello world")
    }

    func testGenerateThrowsEmptyResponseOnEmptyChoices() async {
        MockURLProtocol.requestHandler = { _ in
            (Self.okResponse(), Self.encode(["choices": []]))
        }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.emptyResponse = error else { return XCTFail("expected emptyResponse, got \(error)") }
        }
    }

    func testGenerateThrowsEmptyResponseOnNullContent() async {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": NSNull()]]]]
            return (Self.okResponse(), try! JSONSerialization.data(withJSONObject: body))
        }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.emptyResponse = error else { return XCTFail("expected emptyResponse, got \(error)") }
        }
    }

    func testGenerateTakesFirstChoiceOfMany() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = ["choices": [
                ["message": ["role": "assistant", "content": "first"]],
                ["message": ["role": "assistant", "content": "second"]]
            ]]
            return (Self.okResponse(), try! JSONSerialization.data(withJSONObject: body))
        }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        let result = try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)
        XCTAssertEqual(result, "first")
    }

    func testGenerateReportsTruncationWhenFinishReasonIsLength() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = ["choices": [[
                "message": ["role": "assistant", "content": "partial"],
                "finish_reason": "length"
            ]]]
            return (Self.okResponse(), try! JSONSerialization.data(withJSONObject: body))
        }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        var sawTruncated: Bool?
        let result = try await provider.generate(
            prompt: "p", temperature: nil, timeout: 10,
            truncated: { sawTruncated = $0 }
        )
        XCTAssertEqual(result, "partial")
        XCTAssertEqual(sawTruncated, true)
    }

    func testGenerateThrowsRequestFailedOnNon2xx() async {
        MockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "http://x/v1/chat/completions")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data("server error".utf8))
        }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.requestFailed = error else { return XCTFail("expected requestFailed, got \(error)") }
        }
    }

    func testGenerateThrowsRequestFailedOnErrorField() async {
        MockURLProtocol.requestHandler = { _ in
            (Self.okResponse(), Self.encode(["error": ["message": "bad model"]]))
        }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.requestFailed = error else { return XCTFail("expected requestFailed, got \(error)") }
        }
    }

    func testGenerateThrowsRequestFailedOnMalformedJSON() async {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Data("not json".utf8)) }
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.requestFailed = error else { return XCTFail("expected requestFailed, got \(error)") }
        }
    }

    // MARK: - fetchAvailableModels

    func testFetchAvailableModelsParsesAndSorts() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.absoluteString, "http://localhost:8000/v1/models")
            let body: [String: Any] = ["data": [["id": "zeta"], ["id": "alpha"]]]
            return (Self.okResponse(url: "http://localhost:8000/v1/models"), try! JSONSerialization.data(withJSONObject: body))
        }
        let provider = OMLXProvider(endpoint: "http://localhost:8000/v1", model: "m", urlSession: MockURLProtocol.makeSession())
        let result = try await provider.fetchAvailableModels(endpoint: "http://localhost:8000/v1")
        XCTAssertEqual(result, ["alpha", "zeta"])
    }

    func testFetchAvailableModelsNormalizesEndpointWithChatSuffix() async throws {
        // If the user pasted the full generate URL into Settings, /v1/models should
        // still resolve correctly by stripping `/chat/completions`.
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.absoluteString, "http://localhost:8000/v1/models")
            return (Self.okResponse(url: "http://localhost:8000/v1/models"),
                    try! JSONSerialization.data(withJSONObject: ["data": []]))
        }
        let provider = OMLXProvider(endpoint: "http://localhost:8000/v1/chat/completions", model: "m", urlSession: MockURLProtocol.makeSession())
        _ = try await provider.fetchAvailableModels(endpoint: "http://localhost:8000/v1/chat/completions")
    }

    func testDisplayNameIsOMLX() {
        let provider = OMLXProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(provider.displayName, "oMLX")
    }

    // MARK: - Helpers

    private static func okResponse(url: String = "http://x/v1/chat/completions") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private static func completionsBody(content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }
}
```

- [ ] **Step 2: Register the test file with Xcode**

Run: `scripts/add-to-xcode.rb CasablancaTests CasablancaTests/LLM/OMLXProviderTests.swift`

- [ ] **Step 3: Create the provider**

Create `Casablanca/Services/LLM/OMLXProvider.swift`:

```swift
import Foundation

struct OMLXProvider: LLMProvider {
    let endpoint: String
    let model: String
    let urlSession: URLSession

    var displayName: String { "oMLX" }

    // MARK: - Wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double?
        struct Message: Encodable { let role: String; let content: String }
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]?
        let error: ErrorBody?
        struct Choice: Decodable {
            let message: Message?
            let finish_reason: String?
            struct Message: Decodable { let role: String?; let content: String? }
        }
        struct ErrorBody: Decodable {
            let message: String?
            init(from decoder: Decoder) throws {
                // Accept either { "error": "string" } or { "error": { "message": "string" } }.
                if let container = try? decoder.singleValueContainer(), let s = try? container.decode(String.self) {
                    self.message = s
                    return
                }
                let keyed = try decoder.container(keyedBy: CodingKeys.self)
                self.message = try keyed.decodeIfPresent(String.self, forKey: .message)
            }
            enum CodingKeys: String, CodingKey { case message }
        }
    }

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    // MARK: - LLMProvider

    func generate(
        prompt: String,
        temperature: Double?,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String {
        guard let url = Self.completionsURL(forEndpoint: endpoint) else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [.init(role: "user", content: prompt)],
                stream: false,
                temperature: temperature
            )
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: "Could not reach \(displayName): \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.requestFailed(provider: displayName, message: "\(displayName) returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: body.isEmpty
                    ? "\(displayName) request failed with status \(http.statusCode)."
                    : "\(displayName) request failed: \(body)"
            )
        }

        let payload: ChatResponse
        do {
            payload = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: "\(displayName) returned a malformed response: \(error.localizedDescription)"
            )
        }

        if let err = payload.error?.message, !err.isEmpty {
            throw LLMProviderError.requestFailed(provider: displayName, message: "\(displayName) returned an error: \(err)")
        }

        guard let first = payload.choices?.first,
              let content = first.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.emptyResponse(provider: displayName)
        }

        truncated?(first.finish_reason == "length")
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchAvailableModels(endpoint: String) async throws -> [String] {
        guard let url = Self.modelsURL(forEndpoint: endpoint) else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: "Could not reach \(displayName): \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "unknown"
            throw LLMProviderError.requestFailed(
                provider: displayName,
                message: "\(displayName) model lookup failed with status \(status)."
            )
        }

        let payload = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return payload.data.map(\.id).sorted()
    }

    // MARK: - URL normalization

    /// Normalize a user-supplied endpoint into `<base>/v1/chat/completions`.
    /// Tolerates: bare host, trailing slash, `/v1`, `/v1/`, full path.
    static func completionsURL(forEndpoint endpoint: String) -> URL? {
        guard let base = normalizedBase(endpoint) else { return nil }
        return URL(string: "\(base)/chat/completions")
    }

    /// Normalize into `<base>/models`.
    static func modelsURL(forEndpoint endpoint: String) -> URL? {
        guard let base = normalizedBase(endpoint) else { return nil }
        return URL(string: "\(base)/models")
    }

    /// Returns the `<host>/v1` base with no trailing slash, stripping a trailing
    /// `/chat/completions` if the user pasted the full generate URL.
    private static func normalizedBase(_ endpoint: String) -> String? {
        var s = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/chat/completions") {
            s = String(s.dropLast("/chat/completions".count))
        }
        if s.hasSuffix("/v1/models") {
            s = String(s.dropLast("/models".count))
        }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix("/v1") { return s }
        return "\(s)/v1"
    }
}
```

- [ ] **Step 4: Register the provider with Xcode**

Run: `scripts/add-to-xcode.rb Casablanca Casablanca/Services/LLM/OMLXProvider.swift`

- [ ] **Step 5: Build the test target**

Run without `-quiet` so that any compile errors from the deferred Task 4/5/6 chain are visible:
```bash
xcodebuild build-for-testing -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED. If it fails, the most likely culprit is brace/parenthesis nesting in `LLMProvider.swift`'s factory — check the reported file and line.

- [ ] **Step 6: Run the new provider tests**

Run:
```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/OllamaProviderTests \
  -only-testing:CasablancaTests/OMLXProviderTests
```
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Casablanca/Services/LLM CasablancaTests/LLM Casablanca.xcodeproj
git commit -m "feat(llm): add LLMProvider abstraction with Ollama + oMLX implementations"
```

---

## Task 7: LLMProviderFactory tests

**Files:**
- Create: `CasablancaTests/LLM/LLMProviderFactoryTests.swift`

- [ ] **Step 1: Write the tests**

Create `CasablancaTests/LLM/LLMProviderFactoryTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class LLMProviderFactoryTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultReturnsOllamaProvider() {
        let defaults = makeDefaults()
        let provider = LLMProviderFactory.current(defaults: defaults)
        XCTAssertTrue(provider is OllamaProvider, "expected OllamaProvider, got \(type(of: provider))")
    }

    func testOMLXSelectionReturnsOMLXProvider() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        let provider = LLMProviderFactory.current(defaults: defaults)
        XCTAssertTrue(provider is OMLXProvider, "expected OMLXProvider, got \(type(of: provider))")
    }

    func testSequentialCallsReflectPreferenceChange() {
        let defaults = makeDefaults()
        XCTAssertTrue(LLMProviderFactory.current(defaults: defaults) is OllamaProvider)
        AppPreferences.setLLMProvider(.omlx, in: defaults)
        XCTAssertTrue(LLMProviderFactory.current(defaults: defaults) is OMLXProvider)
    }

    func testOllamaProviderReadsOllamaEndpointAndModel() {
        let defaults = makeDefaults()
        defaults.set("http://10.0.0.5:11434", forKey: AppPreferenceKey.ollamaEndpoint)
        defaults.set("custom-llama", forKey: AppPreferenceKey.ollamaModel)
        let provider = LLMProviderFactory.current(defaults: defaults) as? OllamaProvider
        XCTAssertEqual(provider?.endpoint, "http://10.0.0.5:11434")
        XCTAssertEqual(provider?.model, "custom-llama")
    }

    func testOMLXProviderReadsOMLXEndpointAndModel() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        defaults.set("http://10.0.0.5:8000/v1", forKey: AppPreferenceKey.omlxEndpoint)
        defaults.set("qwen", forKey: AppPreferenceKey.omlxModel)
        let provider = LLMProviderFactory.current(defaults: defaults) as? OMLXProvider
        XCTAssertEqual(provider?.endpoint, "http://10.0.0.5:8000/v1")
        XCTAssertEqual(provider?.model, "qwen")
    }
}
```

- [ ] **Step 2: Register with Xcode**

Run: `scripts/add-to-xcode.rb CasablancaTests CasablancaTests/LLM/LLMProviderFactoryTests.swift`

- [ ] **Step 3: Run the tests**

Run:
```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/LLMProviderFactoryTests
```
Expected: all 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add CasablancaTests/LLM/LLMProviderFactoryTests.swift Casablanca.xcodeproj
git commit -m "test(llm): factory selection + endpoint/model wiring"
```

---

## Task 8: Refactor SummarizationService to use the provider

**Files:**
- Modify: `Casablanca/Services/SummarizationService.swift`

This task swaps in the provider abstraction without changing public behavior. `SummarizationError` stays but two cases gain associated values (`invalidEndpoint(provider:)`, `emptyResponse(provider:)`). The internal `OllamaModel`, `OllamaTagsResponse`, `OllamaGenerateRequest`, `OllamaGenerateResponse` structs and the `makeGenerateURL` / `makeURL` helpers are deleted — they only existed inside this file.

- [ ] **Step 0: Audit for external pattern matches on `SummarizationError` cases**

Run:
```bash
grep -rn 'SummarizationError\.' Casablanca CasablancaTests
```
Expected: only matches inside `Casablanca/Services/SummarizationService.swift` (which this task rewrites). If any other file pattern-matches `SummarizationError.invalidEndpoint` or `.emptyResponse` without an associated-value binding, update it as part of this task. (Confirmed clean as of 2026-05-26.)

- [ ] **Step 1: Replace the file contents**

Replace the entire contents of `Casablanca/Services/SummarizationService.swift` with:

```swift
import Foundation
import Observation

enum SummarizationError: LocalizedError {
    case invalidEndpoint(provider: String)
    case missingSourceMaterial
    case requestFailed(String)
    case emptyResponse(provider: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let provider):
            return "The \(provider) endpoint is invalid. Update it in Settings."
        case .missingSourceMaterial:
            return "Casablanca needs a transcript or notes before it can summarize the meeting."
        case .requestFailed(let message):
            return message
        case .emptyResponse(let provider):
            return "\(provider) returned an empty summary."
        }
    }
}

@MainActor
@Observable
final class SummarizationService {
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

    private(set) var isSummarizing = false
    private(set) var statusMessage = ""
    var errorMessage: String?
    var warningMessage: String?

    func summarize(meeting: Meeting) async throws -> SummaryResponseParser.ParsedResponse {
        let transcript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestampedNotes = meeting.timestampedNotes
            .map { "\($0.formattedTimestamp) \($0.text)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty || !freeformNotes.isEmpty || !timestampedNotes.isEmpty else {
            throw SummarizationError.missingSourceMaterial
        }

        let provider = LLMProviderFactory.current()
        isSummarizing = true
        errorMessage = nil
        warningMessage = nil
        statusMessage = "Sending transcript and notes to \(provider.displayName)..."
        defer { isSummarizing = false }

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

        var wasTruncated = false
        let summary: String
        do {
            summary = try await provider.generate(
                prompt: prompt,
                temperature: nil,
                timeout: 120,
                truncated: { wasTruncated = $0 }
            )
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }

        if wasTruncated {
            warningMessage = "Summary may be truncated: \(provider.displayName) reached its output length limit."
        }

        statusMessage = "Summary generated"
        return SummaryResponseParser.parse(summary)
    }

    func clearError() {
        errorMessage = nil
    }

    func clearWarning() {
        warningMessage = nil
    }

    static func fetchAvailableModels(endpoint: String? = nil) async throws -> [String] {
        let provider = LLMProviderFactory.current()
        let endpointToUse = endpoint ?? Self.currentEndpoint(for: provider)
        do {
            return try await provider.fetchAvailableModels(endpoint: endpointToUse)
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }
    }

    private static func currentEndpoint(for provider: LLMProvider) -> String {
        if provider is OMLXProvider {
            return UserDefaults.standard.string(forKey: AppPreferenceKey.omlxEndpoint) ?? "http://localhost:8000/v1"
        }
        return UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434"
    }

    private static func mapProviderError(_ error: LLMProviderError) -> SummarizationError {
        switch error {
        case .invalidEndpoint(let provider):
            return .invalidEndpoint(provider: provider)
        case .requestFailed(_, let message):
            return .requestFailed(message)
        case .emptyResponse(let provider):
            return .emptyResponse(provider: provider)
        }
    }

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
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run:
```bash
xcodebuild build-for-testing -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run existing summarization tests**

Run:
```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' \
  -only-testing:CasablancaTests/SummarizationServiceTests
```
Expected: existing tests still pass.

- [ ] **Step 4: Commit**

```bash
git add Casablanca/Services/SummarizationService.swift
git commit -m "refactor(llm): SummarizationService delegates to LLMProvider"
```


---

## Task 9: Refactor TerminologyService to use the provider

**Files:**
- Modify: `Casablanca/Services/TerminologyService.swift`

This task deletes the nested `TerminologyService.TerminologyError` enum entirely — the provider now throws `LLMProviderError` directly and `correct(...)` catches it and surfaces a generic warning message.

- [ ] **Step 0: Audit for external references to `TerminologyError`**

Run:
```bash
grep -rn 'TerminologyError' Casablanca CasablancaTests
```
Expected: only matches inside `Casablanca/Services/TerminologyService.swift` (which this task rewrites). If any other file references `TerminologyService.TerminologyError`, update it as part of this task. (Confirmed clean as of 2026-05-26.)

- [ ] **Step 1: Replace the file contents**

Replace `Casablanca/Services/TerminologyService.swift` with:

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
            let corrected = try await runProviderPass(transcript: dictionaryReplaced, entries: entries)
            if Self.looksLikeMangledOutput(input: dictionaryReplaced, output: corrected) {
                warningMessage = "Terminology correction produced unexpected output and was discarded; transcript reflects only deterministic replacements."
                return dictionaryReplaced
            }
            return corrected
        } catch {
            warningMessage = "Terminology correction is unavailable; transcript reflects only deterministic replacements."
            return dictionaryReplaced
        }
    }

    /// Heuristic to detect when the model has mangled the transcript
    /// (e.g. replaced content with `***` redactions, truncated drastically,
    /// or output an apology / explanation instead of a corrected transcript).
    /// Triggers when the alphanumeric character count drops by more than half,
    /// which catches the common failure modes without flagging legitimate
    /// minor edits.
    static func looksLikeMangledOutput(input: String, output: String) -> Bool {
        let inputContent = input.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard inputContent > 100 else { return false }
        let outputContent = output.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        return outputContent * 2 < inputContent
    }

    private func runProviderPass(transcript: String, entries: [TerminologyEntry]) async throws -> String {
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

        return try await LLMProviderFactory.current().generate(
            prompt: prompt,
            temperature: 0,
            timeout: 60,
            truncated: nil
        )
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

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild build-for-testing -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Casablanca/Services/TerminologyService.swift
git commit -m "refactor(llm): TerminologyService delegates to LLMProvider"
```

---

## Task 10: Update SettingsView to expose the provider picker

**Files:**
- Modify: `Casablanca/Views/SettingsView.swift`

This is a UI change. It (a) adds three new `@AppStorage` properties, (b) renames the three model-loading `@State` properties to drop the "Ollama" prefix, (c) replaces the `Section("Ollama (Summarization)")` block with a provider-aware block, and (d) updates the terminology helper text.

- [ ] **Step 1: Replace the `@AppStorage` and `@State` declarations**

In `Casablanca/Views/SettingsView.swift`, replace:

```swift
    @AppStorage(AppPreferenceKey.ollamaEndpoint) private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage(AppPreferenceKey.ollamaModel) private var ollamaModel = "llama3.2"
```

with:

```swift
    @AppStorage(AppPreferenceKey.llmProvider) private var llmProviderRaw: String = LLMProviderKind.ollama.rawValue
    @AppStorage(AppPreferenceKey.ollamaEndpoint) private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage(AppPreferenceKey.ollamaModel) private var ollamaModel = "llama3.2"
    @AppStorage(AppPreferenceKey.omlxEndpoint) private var omlxEndpoint = "http://localhost:8000/v1"
    @AppStorage(AppPreferenceKey.omlxModel) private var omlxModel = ""
```

Replace the three model-state lines:

```swift
    @State private var availableOllamaModels: [String] = []
    @State private var isLoadingOllamaModels = false
    @State private var ollamaModelsError = ""
```

with provider-agnostic names:

```swift
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsError = ""
```

- [ ] **Step 2: Add a computed binding helper**

Just after the `prepTodoStorage` computed property (around line 39), add:

```swift
    private var llmProvider: LLMProviderKind {
        LLMProviderKind(rawValue: llmProviderRaw) ?? .ollama
    }

    private var providerEndpointBinding: Binding<String> {
        switch llmProvider {
        case .ollama: return Binding(get: { ollamaEndpoint }, set: { ollamaEndpoint = $0 })
        case .omlx: return Binding(get: { omlxEndpoint }, set: { omlxEndpoint = $0 })
        }
    }

    private var providerModelBinding: Binding<String> {
        switch llmProvider {
        case .ollama: return Binding(get: { ollamaModel }, set: { ollamaModel = $0 })
        case .omlx: return Binding(get: { omlxModel }, set: { omlxModel = $0 })
        }
    }

    private var providerDisplayName: String {
        switch llmProvider {
        case .ollama: return "Ollama"
        case .omlx: return "oMLX"
        }
    }
```

- [ ] **Step 3: Rename and update the helper functions first**

Do this before touching the section block so the new identifiers exist when the block references them.

Find the computed property `ollamaModelOptions` (currently around `SettingsView.swift:290`) and rename to `modelOptions`. Update its body to use `providerModelBinding.wrappedValue`:

```swift
    private var modelOptions: [String] {
        let current = providerModelBinding.wrappedValue
        if availableModels.contains(current) || current.isEmpty {
            return availableModels
        }
        return [current] + availableModels
    }
```

Find `refreshOllamaModels()` (around `SettingsView.swift:331`) and rename to `refreshModels()`. Update its body to use the provider-agnostic state and the active endpoint:

```swift
    private func refreshModels() async {
        isLoadingModels = true
        modelsError = ""
        defer { isLoadingModels = false }

        let endpoint = providerEndpointBinding.wrappedValue
        do {
            let models = try await SummarizationService.fetchAvailableModels(endpoint: endpoint)
            availableModels = models
            let current = providerModelBinding.wrappedValue
            if current.isEmpty, let firstModel = models.first {
                providerModelBinding.wrappedValue = firstModel
            }
        } catch {
            availableModels = []
            modelsError = error.localizedDescription
        }
    }
```

Also update the `.task` block at the top of `body` (around line 59-62): the call inside should become `await refreshModels()`.

- [ ] **Step 4: Replace the `Ollama (Summarization)` section**

Replace the entire `Section("Ollama (Summarization)") { … }` block (currently `SettingsView.swift:189-244`) with:

```swift
            Section("Local LLM (Summarization)") {
                Picker("Provider", selection: $llmProviderRaw) {
                    Text("Ollama").tag(LLMProviderKind.ollama.rawValue)
                    Text("oMLX").tag(LLMProviderKind.omlx.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: llmProviderRaw) { _, _ in
                    Task { await refreshModels() }
                }

                TextField("Endpoint", text: providerEndpointBinding)
                    .onSubmit {
                        Task { await refreshModels() }
                    }

                HStack(spacing: CasaSpace.md) {
                    Picker("Model", selection: providerModelBinding) {
                        ForEach(modelOptions, id: \.self) { model in
                            if availableModels.contains(model) {
                                Text(model).tag(model)
                            } else {
                                Text("\(model) (not installed)").tag(model)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isLoadingModels || modelOptions.isEmpty)

                    Button("Refresh Models") {
                        Task { await refreshModels() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isLoadingModels)
                }

                if isLoadingModels {
                    HStack(spacing: CasaSpace.sm) {
                        ProgressView().controlSize(.small)
                        Text("Loading installed \(providerDisplayName) models…")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                } else if !modelsError.isEmpty {
                    Text(modelsError)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                } else if availableModels.isEmpty {
                    Text("No \(providerDisplayName) models were found at this endpoint yet.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                } else if !availableModels.contains(providerModelBinding.wrappedValue) {
                    Text("The current model is not installed at this endpoint. Pick one of the detected models above.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }

                Text("Casablanca loads the installed models from \(providerDisplayName) so summarization uses a valid local model.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
```

- [ ] **Step 5: Update the Terminology helper text**

Find the line in the `Section("Terminology")` block (currently `SettingsView.swift:274`) that reads:

```
"When the toggle is on and the list is non-empty, Casablanca runs a deterministic find/replace plus a low-temperature Ollama pass on each new transcript before summarization."
```

Replace with:

```swift
                Text("When the toggle is on and the list is non-empty, Casablanca runs a deterministic find/replace plus a low-temperature local LLM pass on each new transcript before summarization.")
```

- [ ] **Step 6: Build the full app**

Run:
```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Run the full test suite**

Run:
```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' -quiet
```
Expected: all tests pass.

- [ ] **Step 8: Manual smoke test (UI)**

Run the app from Xcode:
- Open Settings → AI tab.
- Verify the section is now titled "Local LLM (Summarization)" with a segmented Provider picker showing "Ollama" and "oMLX".
- Ollama is selected by default; the endpoint reads `http://localhost:11434` and the model field shows the previously-stored model (e.g. `llama3.2`).
- Switch to oMLX; the endpoint flips to `http://localhost:8000/v1` and the model field becomes empty. The model list attempts to refresh and (if oMLX is not running) shows an error.
- Switch back to Ollama; both endpoint and model snap back to the Ollama values.
- Visit the Terminology section; confirm the helper text now reads "low-temperature local LLM pass".

Document the smoke-test result in the commit message.

- [ ] **Step 9: Commit**

```bash
git add Casablanca/Views/SettingsView.swift
git commit -m "feat(settings): add provider picker for Ollama / oMLX

Smoke-tested in Xcode: provider switch updates endpoint+model bindings,
model refresh hits the active provider, terminology helper text uses
provider-agnostic wording."
```

---

## Task 11: Final verification — full test suite + grep audit

**Files:** none modified.

- [ ] **Step 1: Full test run**

Run:
```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca \
  -derivedDataPath .build/test -destination 'platform=macOS' -quiet
```
Expected: all tests pass.

- [ ] **Step 2: Grep audit for stray references**

Run:
```bash
grep -rn 'Ollama' Casablanca CasablancaTests
```
Then visually scan the results. Expected matches (all benign):
- `Casablanca/Services/LLM/OllamaProvider.swift` — the provider implementation, including `var displayName: String { "Ollama" }`.
- `Casablanca/Views/SettingsView.swift` — the picker label `Text("Ollama").tag(...)` and nothing else.
- `CasablancaTests/LLM/OllamaProviderTests.swift` — the provider's own tests.
- `Casablanca/Services/AppleNotesBodyRenderer.swift:101` — a comment about markdown dialects, intentionally left.

Anything else (especially in `SummarizationService.swift`, `TerminologyService.swift`, or other user-facing strings in `SettingsView.swift`) is a stray — fix it.

- [ ] **Step 3: Grep audit for `OllamaGenerateRequest`/`OllamaGenerateResponse`/`OllamaTagsResponse`**

Run:
```bash
grep -rn 'OllamaGenerateRequest\|OllamaGenerateResponse\|OllamaTagsResponse\|makeGenerateURL' Casablanca
```
Expected: no matches. These types lived only in the two services and are now gone.

- [ ] **Step 4: Verify the spec's "Files (changed)" list matches reality**

```bash
git log --name-only fcc4748..HEAD | sort -u
```
Expected to include (at minimum):
- `Casablanca/Models/Meeting.swift`
- `Casablanca/Models/AppPreferences.swift`
- `Casablanca/Services/LLM/LLMProvider.swift`
- `Casablanca/Services/LLM/OllamaProvider.swift`
- `Casablanca/Services/LLM/OMLXProvider.swift`
- `Casablanca/Services/SummarizationService.swift`
- `Casablanca/Services/TerminologyService.swift`
- `Casablanca/Views/SettingsView.swift`
- `CasablancaTests/AppPreferencesTests.swift`
- `CasablancaTests/LLM/*` (4 files)

- [ ] **Step 5: Optional — real end-to-end smoke**

If the user has oMLX installed locally:
1. Start oMLX: `omlx serve --model-dir ~/.omlx/models`
2. In the app, switch Settings → AI → Provider to oMLX.
3. Refresh models; pick one.
4. Record (or open) a meeting with notes/transcript and trigger summarization.
5. Verify the status message reads "Sending transcript and notes to oMLX..." and the summary returns successfully.

If oMLX isn't available, document that the manual oMLX path was not exercised and leave verification to the user.

- [ ] **Step 6: Optional rebase / cleanup**

If commits ended up out of order or task 8/9/10 had to be reordered to make the build green, consider an interactive rebase to produce a clean history before requesting review.

---

## Spec ↔ Plan coverage map

| Spec section / requirement | Task |
|---|---|
| New `llmProvider`, `omlxEndpoint`, `omlxModel` keys | Task 1 |
| `LLMProviderKind` enum + accessors | Task 2 |
| `LLMProviderError` (new type in `LLM/LLMProvider.swift`) | Task 4 |
| `LLMProvider` protocol (instance `fetchAvailableModels`) | Task 4 |
| `LLMProviderFactory.current()` — fresh per call, no caching | Task 4 + Task 7 |
| `OllamaProvider` (URL normalization + request/response) | Task 5 |
| `OMLXProvider` (URL normalization + Chat Completions shape) | Task 6 |
| `finish_reason: "length"` → return partial + warning | Task 6 (test) + Task 8 (`warningMessage`) |
| `looksLikeMangledOutput` stays in TerminologyService | Task 9 (preserved) |
| Settings section rename + picker + provider-aware bindings | Task 10 |
| Five Ollama strings touched in SettingsView (lines 189/223/232/241/274 + state renames) | Task 10 |
| Terminology helper text loses provider-specific wording | Task 10 Step 5 |
| `AppleNotesBodyRenderer.swift:101` comment left as-is | (intentionally untouched) |
| Tests: `OMLXProviderTests`, `OllamaProviderTests`, `LLMProviderFactoryTests`, `LLMProviderKind` round-trip | Tasks 2, 5, 6, 7 |
| Tests: Settings refresh hits new endpoint on switch | Task 10 Step 8 (manual smoke) — automated coverage is intentionally deferred; SwiftUI view tests are out of pattern for this repo |
| Migration: existing users default to `.ollama` | Task 2 (`testLLMProviderDefaultsToOllama`) |
