import XCTest
@testable import Casablanca

final class GitHubReleaseClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.handler = nil
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> URLSessionGitHubReleaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSessionGitHubReleaseClient(owner: "x", repo: "y", session: URLSession(configuration: config))
    }

    func test_fetchLatest_parsesReleaseAndPicksMacOSAsset() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/x/y/releases/latest")
            let body = """
            {"tag_name":"v0.3.0","name":"Casablanca 0.3.0","body":"notes",
             "assets":[
               {"name":"source.zip","browser_download_url":"https://example.com/source.zip","size":1},
               {"name":"Casablanca-0.3.0-macOS.zip","browser_download_url":"https://example.com/asset.zip","size":12345}
             ]}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, body)
        }
        let info = try await makeClient().fetchLatestRelease(includePrereleases: false)
        XCTAssertEqual(info.tag, "v0.3.0")
        XCTAssertEqual(info.version, try SemanticVersion(parsing: "0.3.0"))
        XCTAssertEqual(info.assetURL, URL(string: "https://example.com/asset.zip")!)
        XCTAssertEqual(info.assetByteCount, 12345)
        XCTAssertEqual(info.bodyMarkdown, "notes")
    }

    func test_fetchLatest_includePrereleases_picksFirstFromList() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/x/y/releases")
            let body = """
            [
              {"tag_name":"v0.4.0-beta.1","name":"Beta","body":"b","prerelease":true,
               "assets":[{"name":"Casablanca-0.4.0-beta.1-macOS.zip","browser_download_url":"https://example.com/b.zip","size":2}]}
            ]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, body)
        }
        let info = try await makeClient().fetchLatestRelease(includePrereleases: true)
        XCTAssertEqual(info.version.prerelease, "beta.1")
    }

    func test_fetchLatest_throwsAssetNotFound_whenZipPatternMissing() async throws {
        StubURLProtocol.handler = { request in
            let body = """
            {"tag_name":"v0.3.0","name":"x","body":"x","assets":[
               {"name":"weirdname.zip","browser_download_url":"https://example.com/w.zip","size":1}]}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, body)
        }
        do {
            _ = try await makeClient().fetchLatestRelease(includePrereleases: false)
            XCTFail("expected assetNotFound")
        } catch UpdateError.assetNotFound {
            // ok
        }
    }

    func test_fetchLatest_throwsRateLimited_with429AndRetryAfterHeader() async throws {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!, Data())
        }
        do {
            _ = try await makeClient().fetchLatestRelease(includePrereleases: false)
            XCTFail("expected rateLimited")
        } catch let error as UpdateError {
            switch error {
            case .rateLimited(let retryAfter):
                XCTAssertGreaterThan(retryAfter.timeIntervalSinceNow, 30)
                XCTAssertLessThan(retryAfter.timeIntervalSinceNow, 90)
            default: XCTFail("wrong error: \(error)")
            }
        }
    }

    func test_fetchLatest_throwsMalformed_whenJSONBroken() async throws {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, Data("{".utf8))
        }
        do {
            _ = try await makeClient().fetchLatestRelease(includePrereleases: false)
            XCTFail("expected malformedResponse")
        } catch UpdateError.malformedResponse {}
    }

    func test_redirectDelegate_stripsAuthorizationHeader_acrossOrigin() async {
        // URLSession does not drive a 302 from URLProtocol stubs through the redirect
        // delegate, so we test the delegate method directly with a real URLSession task.
        let session = URLSession(configuration: .ephemeral)
        let originalRequest = URLRequest(url: URL(string: "https://api.github.com/repos/x/y/releases/latest")!)
        let task = session.dataTask(with: originalRequest)

        var newRequest = URLRequest(url: URL(string: "https://objects.githubusercontent.com/redirected")!)
        newRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(url: originalRequest.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": newRequest.url!.absoluteString])!

        let client = URLSessionGitHubReleaseClient(owner: "x", repo: "y")
        var rewritten: URLRequest?
        let expect = expectation(description: "completion handler called")
        client.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: newRequest) { rq in
            rewritten = rq
            expect.fulfill()
        }
        await fulfillment(of: [expect], timeout: 1)
        XCTAssertNil(rewritten?.value(forHTTPHeaderField: "Authorization"))
    }

    func test_redirectDelegate_keepsAuthorizationHeader_sameOrigin() async {
        let session = URLSession(configuration: .ephemeral)
        let originalRequest = URLRequest(url: URL(string: "https://api.github.com/repos/x/y/releases/latest")!)
        let task = session.dataTask(with: originalRequest)

        var newRequest = URLRequest(url: URL(string: "https://api.github.com/redirected")!)
        newRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(url: originalRequest.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": newRequest.url!.absoluteString])!

        let client = URLSessionGitHubReleaseClient(owner: "x", repo: "y")
        var rewritten: URLRequest?
        let expect = expectation(description: "completion handler called")
        client.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: newRequest) { rq in
            rewritten = rq
            expect.fulfill()
        }
        await fulfillment(of: [expect], timeout: 1)
        XCTAssertEqual(rewritten?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)
    static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
