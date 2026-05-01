import XCTest
@testable import Casablanca

final class UpdateDownloaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle(for: type(of: self)).url(forResource: name, withExtension: "zip")!
    }

    // MARK: - download()

    func test_download_writesZipAndReportsProgress() async throws {
        let downloader = DefaultUpdateDownloader()
        let dest = tempDir.appendingPathComponent("out.zip")
        var progressValues: [Double] = []
        let result = try await downloader.download(
            from: fixtureURL("Casablanca-99.0.0-macOS"),
            expectedByteCount: -1,
            to: dest,
            progress: { progressValues.append($0) }
        )
        XCTAssertEqual(result, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThan(progressValues.count, 0)
        XCTAssertEqual(progressValues, progressValues.sorted())
        XCTAssertGreaterThanOrEqual(progressValues.last ?? 0, 0.99)
    }
}

extension UpdateDownloaderTests {
    private func copyFixture(_ name: String) throws -> URL {
        let src = fixtureURL(name)
        let dst = tempDir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    private func setQuarantineXattr(at url: URL) throws {
        let process = Process()
        process.launchPath = "/usr/bin/xattr"
        process.arguments = ["-w", "com.apple.quarantine", "0181;00000000;Casablanca;|nl.medicore.casablanca.fixture", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "xattr write failed")
    }

    private func hasQuarantine(at url: URL) -> Bool {
        let process = Process()
        process.launchPath = "/usr/bin/xattr"
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").contains("com.apple.quarantine")
    }

    func test_extract_unzipsBundle() async throws {
        let zip = try copyFixture("Casablanca-99.0.0-macOS")
        let downloader = DefaultUpdateDownloader()
        let outDir = tempDir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let bundle = try await downloader.extract(zipAt: zip, to: outDir)
        XCTAssertEqual(bundle.lastPathComponent, "Casablanca.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path))
    }

    func test_extract_stripsQuarantineXattrRecursively() async throws {
        let zip = try copyFixture("Casablanca-99.0.0-macOS")
        try setQuarantineXattr(at: zip)
        let downloader = DefaultUpdateDownloader()
        let outDir = tempDir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let bundle = try await downloader.extract(zipAt: zip, to: outDir)
        XCTAssertFalse(hasQuarantine(at: bundle))
        let executable = bundle.appendingPathComponent("Contents/MacOS/Casablanca")
        XCTAssertFalse(hasQuarantine(at: executable))
    }

    func test_extract_throwsUnzipFailed_onCorruptZip() async throws {
        let bad = tempDir.appendingPathComponent("bad.zip")
        try Data("not a zip".utf8).write(to: bad)
        let downloader = DefaultUpdateDownloader()
        let outDir = tempDir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        do {
            _ = try await downloader.extract(zipAt: bad, to: outDir)
            XCTFail("expected throw")
        } catch UpdateError.unzipFailed {}
    }
}

extension UpdateDownloaderTests {
    private func extractedBundle(_ fixtureName: String) async throws -> URL {
        let zip = try copyFixture(fixtureName)
        let outDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return try await DefaultUpdateDownloader().extract(zipAt: zip, to: outDir)
    }

    func test_verify_returnsBundleVersion_whenNewer() async throws {
        let bundle = try await extractedBundle("Casablanca-99.0.0-macOS")
        let v = try await DefaultUpdateDownloader().verify(bundleAt: bundle, currentVersion: try SemanticVersion(parsing: "0.3.0"))
        XCTAssertEqual(v, try SemanticVersion(parsing: "99.0.0"))
    }

    func test_verify_throwsVersionRegression_whenOlder() async throws {
        let bundle = try await extractedBundle("Casablanca-0.0.1-macOS")
        do {
            _ = try await DefaultUpdateDownloader().verify(bundleAt: bundle, currentVersion: try SemanticVersion(parsing: "0.3.0"))
            XCTFail("expected versionRegression")
        } catch UpdateError.versionRegression {}
    }

    func test_verify_throwsCodesignFailed_whenSealBroken() async throws {
        let bundle = try await extractedBundle("Casablanca-99.0.0-macOS")
        // Tamper with the bundle to break the seal
        let resourcesDir = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try "tampered".data(using: .utf8)!.write(to: resourcesDir.appendingPathComponent("extra.txt"))
        do {
            _ = try await DefaultUpdateDownloader().verify(bundleAt: bundle, currentVersion: try SemanticVersion(parsing: "0.3.0"))
            XCTFail("expected codesignFailed")
        } catch UpdateError.codesignFailed {}
    }
}
