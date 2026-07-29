import Foundation

/// Classifies why a provider request failed, so callers (notably the retry
/// policy) can decide whether retrying could plausibly help.
enum LLMFailureKind: Equatable {
    /// URLSession-level transport failure; carries the `URLError.Code` when known.
    case network(URLError.Code?)
    /// The backend returned a non-2xx HTTP status.
    case httpStatus(Int)
    /// The response body could not be decoded into the expected shape.
    case malformedResponse
    /// The backend returned a well-formed response carrying an explicit error.
    case backendError
}

enum LLMProviderError: LocalizedError {
    case invalidEndpoint(provider: String)
    case requestFailed(provider: String, kind: LLMFailureKind, message: String)
    case emptyResponse(provider: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let provider):
            return "The \(provider) endpoint is invalid. Update it in Settings."
        case .requestFailed(_, _, let message):
            return message
        case .emptyResponse(let provider):
            return "\(provider) returned an empty response."
        }
    }

    /// HTTP status codes that signal a transient server-side condition worth retrying.
    private static let transientStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// URLError codes that signal a transient transport condition worth retrying.
    private static let transientNetworkCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .networkConnectionLost,
        .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed
    ]

    /// Whether retrying the same request could plausibly succeed. Network blips
    /// and 5xx/408/429 are transient; 4xx (other than 408/429), malformed bodies
    /// and explicit backend errors are not.
    var isTransient: Bool {
        guard case .requestFailed(_, let kind, _) = self else { return false }
        switch kind {
        case .network(let code):
            // No code means an unclassified transport error — treat as transient
            // (most URLSession failures we can't pin down are connection blips).
            guard let code else { return true }
            return Self.transientNetworkCodes.contains(code)
        case .httpStatus(let code):
            return Self.transientStatusCodes.contains(code)
        case .malformedResponse, .backendError:
            return false
        }
    }
}

/// Local LLM provider. Implementations encapsulate the wire format and URL
/// construction for one backend. Created fresh per call via
/// `LLMProviderFactory.current()`.
protocol LLMProvider {
    /// Human-readable name used in user-facing error messages and the Settings UI.
    var displayName: String { get }

    /// The endpoint URL the provider is currently configured to talk to.
    /// Used by the Settings view to pre-fill the model lookup and by tests.
    var endpoint: String { get }

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
        maxTokens: Int?,
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
        // Reasoning models think out loud before answering, which derails the
        // summary. Off (default) → tell the provider to disable thinking.
        let enableThinking = defaults.bool(forKey: AppPreferenceKey.summaryThinkingEnabled)
        switch AppPreferences.llmProvider(in: defaults) {
        case .ollama:
            return OllamaProvider(
                endpoint: defaults.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434",
                model: defaults.string(forKey: AppPreferenceKey.ollamaModel) ?? "llama3.2",
                urlSession: urlSession,
                enableThinking: enableThinking
            )
        case .omlx:
            return OMLXProvider(
                endpoint: defaults.string(forKey: AppPreferenceKey.omlxEndpoint) ?? "http://localhost:8000/v1",
                model: defaults.string(forKey: AppPreferenceKey.omlxModel) ?? "",
                urlSession: urlSession,
                apiKey: defaults.string(forKey: AppPreferenceKey.omlxAPIKey) ?? "",
                enableThinking: enableThinking
            )
        case .claudeCode:
            // A stored-but-empty model is treated as absent: `--model ""` would fail
            // every call. `enableThinking` does not apply — the CLI has no such switch.
            let storedModel = defaults.string(forKey: AppPreferenceKey.claudeCLIModel) ?? ""
            return ClaudeCLIProvider(
                // Empty path means "auto-detect on the next model fetch".
                endpoint: defaults.string(forKey: AppPreferenceKey.claudeCLIPath) ?? "",
                model: storedModel.isEmpty ? "sonnet" : storedModel,
                runner: ProcessCommandRunner(),
                // The same suite, so the detected-path write-back lands where the
                // caller (and the tests) read it.
                defaults: defaults
            )
        }
    }
}
