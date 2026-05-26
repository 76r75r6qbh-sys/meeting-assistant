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
