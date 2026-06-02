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
                urlSession: urlSession,
                apiKey: defaults.string(forKey: AppPreferenceKey.omlxAPIKey) ?? ""
            )
        }
    }
}
