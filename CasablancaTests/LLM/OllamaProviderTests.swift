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

    func testGenerateReportsTruncationWhenDoneReasonIsLength() async throws {
        MockURLProtocol.requestHandler = { _ in
            (Self.okResponse(), Self.encode(["response": "partial", "done_reason": "length"]))
        }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        var sawTruncated: Bool?
        let result = try await provider.generate(
            prompt: "p", temperature: nil, timeout: 10,
            truncated: { sawTruncated = $0 }
        )
        XCTAssertEqual(result, "partial")
        XCTAssertEqual(sawTruncated, true)
    }

    func testGenerateReportsNoTruncationWhenDoneReasonIsStop() async throws {
        MockURLProtocol.requestHandler = { _ in
            (Self.okResponse(), Self.encode(["response": "complete", "done_reason": "stop"]))
        }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        var sawTruncated: Bool?
        _ = try await provider.generate(
            prompt: "p", temperature: nil, timeout: 10,
            truncated: { sawTruncated = $0 }
        )
        XCTAssertEqual(sawTruncated, false)
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

    func testGenerateThrowsRequestFailedOnMalformedJSON() async {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(), Data("not json".utf8)) }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.generate(prompt: "p", temperature: nil, timeout: 10, truncated: nil)) { error in
            guard case LLMProviderError.requestFailed = error else { return XCTFail("expected requestFailed, got \(error)") }
        }
    }

    func testFetchAvailableModelsThrowsRequestFailedOnMalformedJSON() async {
        MockURLProtocol.requestHandler = { _ in (Self.okResponse(url: "http://x/api/tags"), Data("not json".utf8)) }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.fetchAvailableModels(endpoint: "http://x")) { error in
            guard case LLMProviderError.requestFailed = error else { return XCTFail("expected requestFailed, got \(error)") }
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

    func testFetchAvailableModelsThrowsRequestFailedOnNon2xx() async {
        MockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "http://x/api/tags")!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        let provider = OllamaProvider(endpoint: "http://x", model: "m", urlSession: MockURLProtocol.makeSession())
        await XCTAssertThrowsErrorAsync(try await provider.fetchAvailableModels(endpoint: "http://x")) { error in
            guard case LLMProviderError.requestFailed = error else { return XCTFail("expected requestFailed, got \(error)") }
        }
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
