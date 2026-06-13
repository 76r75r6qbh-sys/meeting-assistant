import Foundation

struct OllamaProvider: LLMProvider {
    let endpoint: String
    let model: String
    let urlSession: URLSession
    let enableThinking: Bool

    init(endpoint: String, model: String, urlSession: URLSession, enableThinking: Bool = true) {
        self.endpoint = endpoint
        self.model = model
        self.urlSession = urlSession
        self.enableThinking = enableThinking
    }

    var displayName: String { "Ollama" }

    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        /// Ollama's native thinking switch (ignored by non-reasoning models).
        let think: Bool?
        let options: Options?
        struct Options: Encodable {
            let temperature: Double?
            let numPredict: Int?
            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
    }

    private struct GenerateResponse: Decodable {
        let response: String?
        let error: String?
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case response
            case error
            case doneReason = "done_reason"
        }
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    func generate(
        prompt: String,
        temperature: Double?,
        maxTokens: Int? = nil,
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
                think: enableThinking ? nil : false,
                options: (temperature == nil && maxTokens == nil)
                    ? nil
                    : GenerateRequest.Options(temperature: temperature, numPredict: maxTokens)
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

        let payload: GenerateResponse
        do {
            payload = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .malformedResponse,
                message: "\(displayName) returned a malformed response: \(error.localizedDescription)"
            )
        }
        if let err = payload.error, !err.isEmpty {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .backendError,
                message: "\(displayName) returned an error: \(err)"
            )
        }

        let text = payload.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw LLMProviderError.emptyResponse(provider: displayName)
        }
        truncated?(payload.doneReason == "length")
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

        let payload: TagsResponse
        do {
            payload = try JSONDecoder().decode(TagsResponse.self, from: data)
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .malformedResponse,
                message: "\(displayName) model lookup returned a malformed response: \(error.localizedDescription)"
            )
        }
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
