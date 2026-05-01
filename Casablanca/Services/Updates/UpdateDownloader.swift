import Foundation
import OSLog

protocol UpdateDownloader {
    func download(
        from url: URL,
        expectedByteCount: Int64,
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL

    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL

    func verify(bundleAt url: URL, currentVersion: SemanticVersion) async throws -> SemanticVersion
}

final class DefaultUpdateDownloader: NSObject, UpdateDownloader, URLSessionDownloadDelegate {
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var resultContinuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    func download(
        from url: URL,
        expectedByteCount: Int64,
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        self.destination = destination

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        self.progressContinuation = continuation

        let progressTask = Task {
            for await value in stream { progress(value) }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.resultContinuation = cont
            let task = session.downloadTask(with: url)
            task.resume()
            _ = progressTask // keep alive
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressContinuation?.yield(min(max(p, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination = destination else { return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            progressContinuation?.yield(1.0)
            progressContinuation?.finish()
            resultContinuation?.resume(returning: destination)
        } catch {
            resultContinuation?.resume(throwing: error)
        }
        resultContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        progressContinuation?.finish()
        let mapped: Error
        if let urlError = error as? URLError {
            mapped = UpdateError.downloadFailed(urlError)
        } else {
            mapped = UpdateError.downloadFailed(URLError(.unknown))
        }
        resultContinuation?.resume(throwing: mapped)
        resultContinuation = nil
    }

    // MARK: extract / verify (fail with fatalError until implemented in Tasks 8 & 9)

    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL {
        fatalError("implement in Task 8")
    }
    func verify(bundleAt url: URL, currentVersion: SemanticVersion) async throws -> SemanticVersion {
        fatalError("implement in Task 9")
    }
}
