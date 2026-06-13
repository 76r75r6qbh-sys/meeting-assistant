import Foundation

struct OMLXProvider: LLMProvider {
    let endpoint: String
    let model: String
    let urlSession: URLSession
    let apiKey: String
    let enableThinking: Bool

    init(endpoint: String, model: String, urlSession: URLSession, apiKey: String = "", enableThinking: Bool = true) {
        self.endpoint = endpoint
        self.model = model
        self.urlSession = urlSession
        self.apiKey = apiKey
        self.enableThinking = enableThinking
    }

    var displayName: String { "oMLX" }

    // MARK: - Wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double?
        let maxTokens: Int?
        /// Passed through to the server's chat-template renderer. Used to set
        /// `enable_thinking: false` for reasoning models (Qwen3.x etc.).
        let chatTemplateKwargs: [String: Bool]?
        struct Message: Encodable { let role: String; let content: String }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case maxTokens = "max_tokens"
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]?
        let error: ErrorBody?
        struct Choice: Decodable {
            let message: Message?
            let finishReason: String?
            struct Message: Decodable { let role: String?; let content: String? }

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        struct ErrorBody: Decodable {
            let message: String?
            init(from decoder: Decoder) throws {
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
        maxTokens: Int? = nil,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String {
        guard let url = Self.completionsURL(forEndpoint: endpoint) else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [.init(role: "user", content: prompt)],
                stream: false,
                temperature: temperature,
                maxTokens: maxTokens,
                chatTemplateKwargs: enableThinking ? nil : ["enable_thinking": false]
            )
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .network((error as? URLError)?.code),
                message: "Could not reach \(displayName): \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .malformedResponse,
                message: "\(displayName) returned an invalid response."
            )
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .httpStatus(http.statusCode),
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
                kind: .malformedResponse,
                message: "\(displayName) returned a malformed response: \(error.localizedDescription)"
            )
        }

        if let err = payload.error?.message, !err.isEmpty {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .backendError,
                message: "\(displayName) returned an error: \(err)"
            )
        }

        guard let first = payload.choices?.first,
              let content = first.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.emptyResponse(provider: displayName)
        }

        truncated?(first.finishReason == "length")
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchAvailableModels(endpoint: String) async throws -> [String] {
        guard let url = Self.modelsURL(forEndpoint: endpoint) else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .network((error as? URLError)?.code),
                message: "Could not reach \(displayName): \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: status.map { .httpStatus($0) } ?? .malformedResponse,
                message: "\(displayName) model lookup failed with status \(status.map(String.init) ?? "unknown")."
            )
        }

        let payload: ModelsResponse
        do {
            payload = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .malformedResponse,
                message: "\(displayName) model lookup returned a malformed response: \(error.localizedDescription)"
            )
        }
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
        if s.hasSuffix("/models") {
            s = String(s.dropLast("/models".count))
        }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix("/v1") { return s }
        return "\(s)/v1"
    }
}
