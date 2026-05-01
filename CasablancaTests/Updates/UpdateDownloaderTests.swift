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
