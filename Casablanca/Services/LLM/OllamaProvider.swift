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
        truncated?(false)
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
