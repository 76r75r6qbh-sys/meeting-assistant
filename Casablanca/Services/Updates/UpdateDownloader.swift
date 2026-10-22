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
    /// The code requirement a downloaded bundle must satisfy: our bundle id,
    /// signed by an Apple-issued certificate of our team. Must match the
    /// `designated` requirement in `scripts/casablanca.req` that release builds
    /// are signed with (a test pins the two together). Plain
    /// `codesign --verify` would also accept an ad-hoc signature by anyone.
    static let releaseCodeRequirement =
        #"identifier "com.casablanca.app" and anchor apple generic and certificate leaf[subject.OU] = "77YQ5E8KT3""#

    /// Upper bound for `ditto` / `xattr` / `codesign` on a staged update.
    private static let commandTimeout: TimeInterval = 300

    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")
    private let codeRequirement: String
    private let runner: CommandRunning
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var resultContinuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var expectedByteCount: Int64 = -1

    /// `codeRequirement` is injectable only so tests can verify ad-hoc-signed
    /// fixtures; production always uses `releaseCodeRequirement`.
    init(
        codeRequirement: String = DefaultUpdateDownloader.releaseCodeRequirement,
        runner: CommandRunning = ProcessCommandRunner()
    ) {
        self.codeRequirement = codeRequirement
        self.runner = runner
        super.init()
    }

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
        self.expectedByteCount = expectedByteCount

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
            // A session retains its delegate until invalidated: let this one
            // finish its task, then release us.
            session.finishTasksAndInvalidate()
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
            // The release metadata states the asset size; a mismatch means a
            // truncated or substituted download.
            if expectedByteCount > 0 {
                let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
                guard size == expectedByteCount else {
                    logger.error("download size \(size ?? -1) != expected \(self.expectedByteCount)")
                    progressContinuation?.finish()
                    throw UpdateError.downloadFailed(URLError(.cannotDecodeContentData))
                }
            }
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

    // MARK: extract / verify (verify still has fatalError until implemented in Task 9)

    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", source.path, destinationDir.path], errorOnFailure: .unzipFailed)
        let appURL = destinationDir.appendingPathComponent("Casablanca.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw UpdateError.unzipFailed }
        do {
            try await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path], errorOnFailure: nil)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.quarantineStripFailed(error.localizedDescription)
        }
        return appURL
    }

    /// Runs a tool via `ProcessCommandRunner`, which drains stdout and stderr
    /// while the child runs (waiting for exit first deadlocks once a pipe's
    /// ~64 KB buffer fills, e.g. `ditto` or `codesign --deep` being verbose).
    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String], errorOnFailure: UpdateError?) async throws -> String {
        let result: CommandResult
        do {
            result = try await runner.run(
                executable: launchPath,
                arguments: arguments,
                standardInput: "",
                workingDirectory: nil,
                timeout: Self.commandTimeout
            )
        } catch {
            if let errorOnFailure { throw errorOnFailure }
            throw UpdateError.quarantineStripFailed("\(launchPath) failed: \(error)")
        }
        if result.exitCode != 0 {
            if let error = errorOnFailure { throw error }
            throw UpdateError.quarantineStripFailed("\(launchPath) exited \(result.exitCode): \(result.standardError)")
        }
        return result.standardOutput
    }

    func verify(bundleAt url: URL, currentVersion: SemanticVersion) async throws -> SemanticVersion {
        // `-R` pins WHO signed it, not just that the seal is intact.
        try await run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "-R", "=" + codeRequirement, url.path],
            errorOnFailure: .codesignFailed
        )

        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoPlist),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let raw = plist["CFBundleShortVersionString"] as? String
        else {
            throw UpdateError.unzipFailed
        }
        let bundleVersion: SemanticVersion
        do { bundleVersion = try SemanticVersion(parsing: raw) }
        catch { throw UpdateError.unzipFailed }

        guard bundleVersion > currentVersion else { throw UpdateError.versionRegression }
        return bundleVersion
    }
}
