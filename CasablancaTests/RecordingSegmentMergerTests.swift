import XCTest
@testable import Casablanca

/// Golden-fixture pinning tests for `RecordingSegmentMerger` (Phase 1b).
///
/// These pin the EXACT byte output of the current implementation so the
/// Phase 1c `WAVCodec` unification cannot silently change the on-disk format.
/// The expected byte arrays are literal constants captured from the current
/// implementation, NOT recomputed via the production function under test.
/// To regenerate after an intentional format change, dump the bytes:
///   `print([UInt8](RecordingSegmentMerger.header(dataByteCount: N)))`.
final class RecordingSegmentMergerGoldenTests: XCTestCase {
    // MARK: - header(dataByteCount:) golden fixtures

    func testHeaderForZeroDataBytes() {
        let expected: [UInt8] = [
            82, 73, 70, 70, 36, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32,
            16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0,
            16, 0, 100, 97, 116, 97, 0, 0, 0, 0,
        ]
        XCTAssertEqual([UInt8](RecordingSegmentMerger.header(dataByteCount: 0)), expected)
    }

    func testHeaderForEightDataBytes() {
        let expected: [UInt8] = [
            82, 73, 70, 70, 44, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32,
            16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0,
            16, 0, 100, 97, 116, 97, 8, 0, 0, 0,
        ]
        XCTAssertEqual([UInt8](RecordingSegmentMerger.header(dataByteCount: 8)), expected)
    }

    func testHeaderForTwelveDataBytes() {
        let expected: [UInt8] = [
            82, 73, 70, 70, 48, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32,
            16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0,
            16, 0, 100, 97, 116, 97, 12, 0, 0, 0,
        ]
        XCTAssertEqual([UInt8](RecordingSegmentMerger.header(dataByteCount: 12)), expected)
    }

    func testHeaderForOneHundredDataBytes() {
        let expected: [UInt8] = [
            82, 73, 70, 70, 136, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32,
            16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0,
            16, 0, 100, 97, 116, 97, 100, 0, 0, 0,
        ]
        XCTAssertEqual([UInt8](RecordingSegmentMerger.header(dataByteCount: 100)), expected)
    }

    // MARK: - Header field decoding (human-readable invariants)

    func testHeaderFieldsAreSixteenKHzMono16Bit() {
        let header = RecordingSegmentMerger.header(dataByteCount: 18)
        XCTAssertEqual(header.count, 44)

        XCTAssertEqual(String(data: header.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: header.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: header.subdata(in: 36..<40), encoding: .ascii), "data")

        XCTAssertEqual(readUInt32LE(header, at: 4), UInt32(36 + 18))   // RIFF chunk size
        XCTAssertEqual(readUInt32LE(header, at: 16), 16)              // fmt chunk size
        XCTAssertEqual(readUInt16LE(header, at: 20), 1)              // PCM format tag
        XCTAssertEqual(readUInt16LE(header, at: 22), 1)              // channels = mono
        XCTAssertEqual(readUInt32LE(header, at: 24), 16_000)        // sample rate
        XCTAssertEqual(readUInt32LE(header, at: 28), 32_000)        // byte rate = 16000 * 2
        XCTAssertEqual(readUInt16LE(header, at: 32), 2)             // block align
        XCTAssertEqual(readUInt16LE(header, at: 34), 16)           // bits per sample
        XCTAssertEqual(readUInt32LE(header, at: 40), 18)         // data chunk size
    }

    // MARK: - End-to-end merge byte pin

    func testMergeProducesExactGoldenBytes() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let segment1: [Int16] = [1, -1, 100, -100]
        let segment2: [Int16] = [32767, -32768]
        let segment3: [Int16] = [0, 7, 255]

        let urls = try [segment1, segment2, segment3].enumerated().map { index, samples -> URL in
            let url = directory.appendingPathComponent("segment-\(index).wav")
            try writeWAV(samples: samples, to: url)
            return url
        }

        let outputURL = directory.appendingPathComponent("merged.wav")
        let duration = try RecordingSegmentMerger.merge(segmentURLs: urls, into: outputURL)

        // 9 samples total (4 + 2 + 3) at 16 kHz.
        XCTAssertEqual(duration, 9.0 / 16_000.0, accuracy: 1e-9)

        let expected: [UInt8] = [
            // RIFF header: data size 18, RIFF chunk size 54 (36 + 18)
            82, 73, 70, 70, 54, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32,
            16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0,
            16, 0, 100, 97, 116, 97, 18, 0, 0, 0,
            // PCM payload (little-endian Int16): 1, -1, 100, -100, 32767, -32768, 0, 7, 255
            1, 0, 255, 255, 100, 0, 156, 255, 255, 127, 0, 128, 0, 0, 7, 0, 255, 0,
        ]
        let actual = [UInt8](try Data(contentsOf: outputURL))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 62)
    }

    func testMergeSingleSegmentRoundTripsPayload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let samples: [Int16] = [10, -20, 30, -40, 50]
        let segmentURL = directory.appendingPathComponent("only.wav")
        try writeWAV(samples: samples, to: segmentURL)

        let outputURL = directory.appendingPathComponent("merged.wav")
        _ = try RecordingSegmentMerger.merge(segmentURLs: [segmentURL], into: outputURL)

        let output = try Data(contentsOf: outputURL)
        let header = output.prefix(44)
        let payload = output.dropFirst(44)

        XCTAssertEqual([UInt8](header), [UInt8](RecordingSegmentMerger.header(dataByteCount: 10)))
        let decoded = payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(decoded, samples)
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSegmentMergerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Hand-crafts a minimal valid 16 kHz mono 16-bit WAV using the same header
    /// builder production uses to create segment files, then appends raw PCM.
    private func writeWAV(samples: [Int16], to url: URL) throws {
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let data = RecordingSegmentMerger.header(dataByteCount: payload.count) + payload
        try data.write(to: url)
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }
}
