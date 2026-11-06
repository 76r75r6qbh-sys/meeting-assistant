import AVFoundation
import FluidAudio
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

    /// Writes `left` and `right` as a 48 kHz stereo float WAV.
    private func writeStereo48k(left: [Float], right: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        buffer.frameLength = AVAudioFrameCount(left.count)
        for (channel, values) in [left, right].enumerated() {
            values.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: values.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Stereo is averaged to mono, not reduced to the left channel.
    func testResamplesStereoToSixteenKilohertzMonoAverage() throws {
        let url = directory.appendingPathComponent("track48k.wav")
        let left = steppedSamples(rate: 48_000)
        try writeStereo48k(left: left, right: left.map { $0 + 0.2 }, to: url)

        let samples = try VoiceSpanExtractor.samples(url: url, ranges: [1.0...2.0])

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 64, "One second at 16 kHz")
        let middle = samples[4_000..<12_000]
        // Second 1: left 0.3, right 0.5 → 0.4.
        XCTAssertTrue(middle.allSatisfy { abs($0 - 0.4) < 0.02 }, "Average of both channels, got \(middle.first ?? .nan)")
    }

    /// AAC's `length` is an estimate: a range up to `file.length` (and past
    /// it, clamped) must read what is there instead of failing.
    func testM4ARangeEndingAtTheFileLengthReads() throws {
        let url = directory.appendingPathComponent("track.m4a")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let values = SyntheticSignal.noise(seed: 3, count: 16_000 * 3, amplitude: 0.3)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: values.count) }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let length = try AVAudioFile(forReading: url).length
        let end = Double(length) / 16_000

        let samples = try VoiceSpanExtractor.samples(url: url, ranges: [(end - 1)...end, end...(end + 5)])

        XCTAssertGreaterThan(samples.count, 8_000, "The last second reads (at least most of it)")
        XCTAssertLessThanOrEqual(samples.count, 16_000 + 64)
    }

    /// A reader over `count` frames of 1.0 that throws for any read crossing
    /// `tail` (AAC's phantom tail), and records each read.
    private final class TailReader {
        let tail: Int
        private(set) var reads: [(offset: Int, count: Int)] = []
        init(tail: Int) { self.tail = tail }
        func read(_ offset: Int, _ count: Int) throws -> [Float] {
            reads.append((offset, count))
            if offset + count > tail { throw CocoaError(.fileReadUnknown) }
            return [Float](repeating: 1, count: count)
        }
    }

    /// A range of 1 s or less is a single read; when it crosses the tail the
    /// reader backs off (4096, then 512 frames) and keeps the real frames.
    func testSingleChunkRangeBacksOffAtTheTailAndKeepsRealFrames() throws {
        let reader = TailReader(tail: 12_000)

        let result = try VoiceSpanExtractor.readFrames(total: 16_000, chunk: 48_000, read: reader.read)

        XCTAssertEqual(result.samples.count, 11_776, "Every whole 512-frame read before frame 12 000")
        XCTAssertTrue(result.samples.allSatisfy { $0 == 1 })
        XCTAssertNotNil(result.failure, "Stopped at the tail")
        XCTAssertEqual(reader.reads.first?.count, 16_000)
        XCTAssertTrue(reader.reads.contains { $0.count == 4_096 } && reader.reads.contains { $0.count == 512 })
    }

    /// A longer range keeps its earlier chunks and the real frames of the
    /// chunk that crossed the tail (no second of audio dropped).
    func testLongRangeKeepsTheRealFramesOfTheThrowingChunk() throws {
        let reader = TailReader(tail: 100_000)

        let result = try VoiceSpanExtractor.readFrames(total: 120_000, chunk: 48_000, read: reader.read)

        XCTAssertGreaterThanOrEqual(result.samples.count, 100_000 - 512)
        XCTAssertLessThanOrEqual(result.samples.count, 100_000)
        XCTAssertNotNil(result.failure)
    }

    func testReadFramesEdgeCases() throws {
        let nothing = try VoiceSpanExtractor.readFrames(total: 10, chunk: 4) { _, _ in throw CocoaError(.fileReadUnknown) }
        XCTAssertTrue(nothing.samples.isEmpty)
        XCTAssertNotNil(nothing.failure, "Returned to the caller, which decides")

        XCTAssertThrowsError(try VoiceSpanExtractor.readFrames(total: 10, chunk: 4) { _, _ in throw CancellationError() }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let short = try VoiceSpanExtractor.readFrames(total: 10, chunk: 4) { _, _ in [1, 1] }
        XCTAssertEqual(short.samples.count, 2, "A short read ends the range")
        XCTAssertNil(short.failure)
    }

    /// A range whose every read threw is an error only when nothing was
    /// produced yet and it starts before the last second of the file.
    func testEndOfFileRule() {
        XCTAssertTrue(VoiceSpanExtractor.isEndOfFile(rangeStart: 0, fileLength: 160_000, rate: 16_000, producedAudio: true))
        XCTAssertTrue(VoiceSpanExtractor.isEndOfFile(rangeStart: 150_000, fileLength: 160_000, rate: 16_000, producedAudio: false))
        XCTAssertFalse(VoiceSpanExtractor.isEndOfFile(rangeStart: 100_000, fileLength: 160_000, rate: 16_000, producedAudio: false))
    }

    func testNoSpeechFromFluidAudioIsOurNoSpeechInRanges() {
        let mapped = FluidAudioDiarizer.embeddingError(OfflineDiarizationError.noSpeechDetected)
        XCTAssertEqual(mapped as? SpeakerDiarizerError, .noSpeechInRanges)
        XCTAssertTrue(FluidAudioDiarizer.embeddingError(CocoaError(.fileReadCorruptFile)) is CocoaError)
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
