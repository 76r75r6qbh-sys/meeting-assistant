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
