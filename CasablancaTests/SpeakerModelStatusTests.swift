import XCTest
@testable import Casablanca

final class SpeakerModelStatusTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Models downloaded on an earlier launch show as Ready, not "Not downloaded".
    func testCachedModelsOnDiskShowReady() throws {
        for url in FluidAudioDiarizer.requiredModelURLs(in: directory) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension == "mlmodelc" {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }

        XCTAssertEqual(SpeakerModelStatus.initialState(modelsDirectory: directory), .ready)
    }

    func testPartialOrMissingModelsShowNotDownloaded() throws {
        XCTAssertEqual(SpeakerModelStatus.initialState(modelsDirectory: directory), .notDownloaded)

        let first = try XCTUnwrap(FluidAudioDiarizer.requiredModelURLs(in: directory).first)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        XCTAssertEqual(SpeakerModelStatus.initialState(modelsDirectory: directory), .notDownloaded)
    }
}
