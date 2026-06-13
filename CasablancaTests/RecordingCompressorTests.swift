import AVFoundation
import XCTest
@testable import Casablanca

/// Tests for the AAC/m4a compression post-processing step (Phase 3d).
///
/// Compression runs only AFTER transcription and is purely additive: it reads
/// the finished 16 kHz mono WAV mixdown and writes a much smaller AAC/m4a. It
/// must never alter the WAV-production paths (those are golden-pinned), and on
/// failure it must leave the input WAV intact so a recording is never lost.
final class RecordingCompressorTests: XCTestCase {
    // MARK: - Success path

    func testCompressProducesLoadableM4aWithAudioTrackAndMatchingDuration() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1 second of 16 kHz mono audio: a quiet sine so the encoder has real signal.
        let sampleRate = 16_000
        let samples = makeSineSamples(count: sampleRate, sampleRate: sampleRate, frequency: 440)
        let wavURL = directory.appendingPathComponent("recording.wav")
        try writeWAV(samples: samples, to: wavURL)

        let outputURL = try await RecordingCompressor.compress(wavURL: wavURL)

        XCTAssertEqual(outputURL.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Loadable as an AVAsset with an audio track.
        let asset = AVURLAsset(url: outputURL)
        let tracks = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1, "Compressed file should have exactly one audio track")

        // Loadable as an AVAudioFile (proves it is real decodable audio).
        let audioFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThan(audioFile.length, 0)

        // Duration ~ 1.0s within tolerance (AAC priming/padding shifts it slightly).
        let duration = asset.duration.seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.2)
    }

    func testCompressedOutputIsSmallerThanWAV() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sampleRate = 16_000
        // 3 seconds so the per-file AAC overhead doesn't dominate.
        let samples = makeSineSamples(count: sampleRate * 3, sampleRate: sampleRate, frequency: 440)
        let wavURL = directory.appendingPathComponent("recording.wav")
        try writeWAV(samples: samples, to: wavURL)

        let wavSize = try fileSize(of: wavURL)
        let outputURL = try await RecordingCompressor.compress(wavURL: wavURL)
        let m4aSize = try fileSize(of: outputURL)

        XCTAssertLessThan(m4aSize, wavSize, "AAC/m4a should be smaller than the source WAV")
    }

    // MARK: - Deletion semantics

    func testCompressLeavesInputWAVInPlace() async throws {
        // The compressor itself returns the m4a URL but does NOT delete the WAV;
        // the caller deletes it only after a successful return. Verify the
        // compressor preserves its input.
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let samples = makeSineSamples(count: 16_000, sampleRate: 16_000, frequency: 440)
        let wavURL = directory.appendingPathComponent("recording.wav")
        try writeWAV(samples: samples, to: wavURL)

        _ = try await RecordingCompressor.compress(wavURL: wavURL)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wavURL.path),
            "Compressor must not delete its input WAV"
        )
    }

    // MARK: - Failure path

    func testCompressOnInvalidWAVThrowsAndLeavesNoOutput() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Not a real WAV — garbage bytes with a .wav extension.
        let wavURL = directory.appendingPathComponent("broken.wav")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]).write(to: wavURL)

        do {
            _ = try await RecordingCompressor.compress(wavURL: wavURL)
            XCTFail("Expected compression of an invalid WAV to throw")
        } catch {
            // Expected.
        }

        // Input is preserved; no partial output left behind.
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path), "Input WAV must be preserved on failure")
        let outputURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), "No partial m4a should remain on failure")
    }

    func testCompressOnMissingFileThrows() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")

        do {
            _ = try await RecordingCompressor.compress(wavURL: missingURL)
            XCTFail("Expected compression of a missing file to throw")
        } catch {
            // Expected.
        }
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingCompressorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Hand-crafts a minimal valid 16 kHz mono 16-bit WAV using the same header
    /// builder production uses (mirrors `RecordingSegmentMergerGoldenTests`).
    private func writeWAV(samples: [Int16], to url: URL) throws {
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let data = WAVCodec.header(dataByteCount: payload.count) + payload
        try data.write(to: url)
    }

    private func makeSineSamples(count: Int, sampleRate: Int, frequency: Double) -> [Int16] {
        (0..<count).map { i in
            let t = Double(i) / Double(sampleRate)
            let value = sin(2 * Double.pi * frequency * t) * 0.5
            return Int16((value * Double(Int16.max)).rounded())
        }
    }

    private func fileSize(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }
}
