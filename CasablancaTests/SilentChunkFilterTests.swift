import WhisperKit
import XCTest
@testable import Casablanca

/// The filter is pure arithmetic over sample arrays, so every case here builds
/// its audio by hand — no fixture file, no model, no `UserDefaults`.
final class SilentChunkFilterTests: XCTestCase {
    private let sampleRate = 16_000
    /// `EnergyVAD`'s default frame is 0.1 s, so this is exactly one VAD frame.
    private var frameSamples: Int { sampleRate / 10 }

    // MARK: - Helpers

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(Double(sampleRate) * seconds))
    }

    /// 30 s of silence with a single `frameSamples`-long burst at `atFrame`, so
    /// the VAD sees exactly one voiced frame.
    private func oneBurst(amplitude: Float, atFrame frameIndex: Int) -> [Float] {
        var samples = silence(seconds: 30)
        let start = frameIndex * frameSamples
        for index in start..<(start + frameSamples) {
            samples[index] = amplitude
        }
        return samples
    }

    // MARK: - Dropping silence

    func testAllZeroChunkIsDroppedAndCountedInSeconds() {
        let chunk = AudioChunk(seekOffsetIndex: 0, audioSamples: silence(seconds: 30))

        let outcome = SilentChunkFilter.partition([chunk], vad: EnergyVAD())

        XCTAssertTrue(outcome.kept.isEmpty)
        XCTAssertEqual(outcome.droppedCount, 1)
        XCTAssertEqual(outcome.droppedSeconds, 30, accuracy: 0.0001)
    }

    func testEmptyInputYieldsEmptyOutcome() {
        let outcome = SilentChunkFilter.partition([], vad: EnergyVAD())

        XCTAssertTrue(outcome.kept.isEmpty)
        XCTAssertEqual(outcome.droppedCount, 0)
        XCTAssertEqual(outcome.droppedSeconds, 0, accuracy: 0.0001)
    }

    // MARK: - minVoicedFrames

    func testSingleVoicedFrameIsKeptAtTheDefaultMinimum() {
        let chunk = AudioChunk(seekOffsetIndex: 0, audioSamples: oneBurst(amplitude: 0.1, atFrame: 10))

        let outcome = SilentChunkFilter.partition([chunk], vad: EnergyVAD(), minVoicedFrames: 1)

        XCTAssertEqual(outcome.kept.count, 1)
        XCTAssertEqual(outcome.droppedCount, 0)
        XCTAssertEqual(outcome.droppedSeconds, 0, accuracy: 0.0001)
    }

    func testSingleVoicedFrameIsDroppedWhenThreeAreRequired() {
        let chunk = AudioChunk(seekOffsetIndex: 0, audioSamples: oneBurst(amplitude: 0.1, atFrame: 10))

        let outcome = SilentChunkFilter.partition([chunk], vad: EnergyVAD(), minVoicedFrames: 3)

        XCTAssertTrue(outcome.kept.isEmpty)
        XCTAssertEqual(outcome.droppedCount, 1)
        XCTAssertEqual(outcome.droppedSeconds, 30, accuracy: 0.0001)
    }

    // MARK: - Order and seek offsets

    /// The kept chunks are fed straight to `transcribeWithOptions` alongside
    /// `seekOffsets`, so a reordered or renumbered chunk would place its text at
    /// the wrong point in the meeting.
    func testOrderAndSeekOffsetIndexArePreserved() {
        let voiced = oneBurst(amplitude: 0.1, atFrame: 10)
        let chunks = [
            AudioChunk(seekOffsetIndex: 0, audioSamples: voiced),
            AudioChunk(seekOffsetIndex: 480_000, audioSamples: silence(seconds: 30)),
            AudioChunk(seekOffsetIndex: 960_000, audioSamples: voiced),
            AudioChunk(seekOffsetIndex: 1_440_000, audioSamples: voiced),
        ]

        let outcome = SilentChunkFilter.partition(chunks, vad: EnergyVAD())

        XCTAssertEqual(outcome.kept.map(\.seekOffsetIndex), [0, 960_000, 1_440_000])
        XCTAssertEqual(outcome.droppedCount, 1)
        XCTAssertEqual(outcome.droppedSeconds, 30, accuracy: 0.0001)
    }

    // MARK: - The energy threshold is the VAD's, not the filter's

    func testQuietNoiseIsDroppedAtTheDefaultThresholdAndKeptAtALowerOne() {
        let noise = [Float](repeating: 0.01, count: 480_000)
        let chunk = AudioChunk(seekOffsetIndex: 0, audioSamples: noise)

        let dropped = SilentChunkFilter.partition([chunk], vad: EnergyVAD(energyThreshold: 0.02))
        XCTAssertTrue(dropped.kept.isEmpty)
        XCTAssertEqual(dropped.droppedCount, 1)

        let kept = SilentChunkFilter.partition([chunk], vad: EnergyVAD(energyThreshold: 0.005))
        XCTAssertEqual(kept.kept.count, 1)
        XCTAssertEqual(kept.droppedCount, 0)
    }
}
