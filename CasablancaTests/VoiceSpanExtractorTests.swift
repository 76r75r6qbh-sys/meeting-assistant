import AVFoundation
import XCTest
@testable import Casablanca

/// "Remember voice…" must analyse only the consented speaker's ranges: the
/// extractor reads just those spans, in memory, at 16 kHz mono.
final class VoiceSpanExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceSpanExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// One second each at 0.1, 0.3, 0.5, 0.7: a sample's value says which
    /// second of the track it came from.
    private func steppedSamples(rate: Int) -> [Float] {
        [0.1, 0.3, 0.5, 0.7].flatMap { [Float](repeating: $0, count: rate) }
    }

    func testReadsOnlyTheRangesJoinedBySilence() throws {
        let url = directory.appendingPathComponent("track.wav")
        try SyntheticSignal.writeWAV(steppedSamples(rate: 16_000), to: url)

        let samples = try VoiceSpanExtractor.samples(url: url, ranges: [2.25...2.5, 1.0...1.5])

        // Time order: 0.5 s of second 1, 0.5 s silence, 0.25 s of second 2.
        XCTAssertEqual(samples.count, 8_000 + 8_000 + 4_000)
        XCTAssertTrue(samples[0..<8_000].allSatisfy { abs($0 - 0.3) < 0.01 }, "Only second 1's audio, nothing before it")
        XCTAssertTrue(samples[8_000..<16_000].allSatisfy { $0 == 0 }, "Silence between the ranges")
        XCTAssertTrue(samples[16_000...].allSatisfy { abs($0 - 0.5) < 0.01 }, "Only second 2's audio")
        XCTAssertFalse(samples.contains { abs($0 - 0.1) < 0.01 || abs($0 - 0.7) < 0.01 }, "Nothing outside the ranges")
    }

    func testResamplesToSixteenKilohertzMono() throws {
        let url = directory.appendingPathComponent("track48k.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let values = steppedSamples(rate: 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        for channel in 0..<2 {
            values.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: values.count) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        let samples = try VoiceSpanExtractor.samples(url: url, ranges: [1.0...2.0])

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 64, "One second at 16 kHz")
        let middle = samples[4_000..<12_000]
        XCTAssertTrue(middle.allSatisfy { abs($0 - 0.3) < 0.02 }, "Mono mix of second 1")
    }

    func testRangesAreClampedToTheFile() throws {
        let url = directory.appendingPathComponent("track.wav")
        try SyntheticSignal.writeWAV(steppedSamples(rate: 16_000), to: url)

        let samples = try VoiceSpanExtractor.samples(url: url, ranges: [3.5...10, 20...30])

        XCTAssertEqual(samples.count, 8_000, "Half a second left in the file; the range past the end adds nothing")
    }

    func testDominantEmbeddingIsTheClusterWithMostSpeech() throws {
        let embedding = try XCTUnwrap(FluidAudioDiarizer.dominantEmbedding(
            durations: [("S1", 2), ("S2", 3), ("S1", 0.5), ("S3", 4)],
            database: ["S1": [1, 0], "S2": [0, 3], "S3": [0, 0]]
        ))

        // S3 has the most speech but no usable vector; S2 (3 s) beats S1 (2.5 s).
        XCTAssertEqual(embedding, [0, 1])
        XCTAssertNil(FluidAudioDiarizer.dominantEmbedding(durations: [], database: ["S1": [1, 0]]))
    }
}
