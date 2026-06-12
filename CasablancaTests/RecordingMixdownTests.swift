import XCTest
@testable import Casablanca

/// Golden-fixture pinning tests for the recording mixdown (Phase 1b).
///
/// `mixTemporaryRecordings()` is private to `RecordingSession` and needs audio
/// hardware (a running `AVAudioEngine` + `SCStream`) to reach, so it cannot be
/// invoked headlessly. The load-bearing, hardware-independent part is the
/// per-frame mixing arithmetic. Phase 1b lifted that loop verbatim into the
/// `RecordingSession.mixFrames(microphoneSamples:systemAudioSamples:)` seam
/// (internal, body unchanged) so it can be pinned here.
///
/// The mixing formula being pinned:
///   sample = mic[i] * 1.35 + system[i] * 0.8   (each term present only if in range)
///   clamped = clamp(sample, -1, 1)
///   out[i]  = Int16((clamped * 32767).rounded())
///   frameCount = max(mic.count, system.count); the shorter track contributes 0
///   beyond its length (tail handling).
///
/// Expected values are literal constants captured from the current
/// implementation, NOT recomputed via the function under test.
final class RecordingMixdownTests: XCTestCase {
    func testOverlappingFramesUseExactMixFormulaAndClamping() {
        let mic: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 0.25]
        let system: [Float] = [0.0, 0.5, -0.5, 0.5, -0.5, 0.1]

        // index 1: 0.5*1.35 + 0.5*0.8 = 1.075 -> clamp 1.0 -> 32767
        // index 4: -1.0*1.35 + -0.5*0.8 = -1.75 -> clamp -1.0 -> -32767
        // index 5: 0.25*1.35 + 0.1*0.8 = 0.4175 -> 13680
        let expected: [Int16] = [0, 32767, -32767, 32767, -32767, 13680]
        XCTAssertEqual(
            RecordingSession.mixFrames(microphoneSamples: mic, systemAudioSamples: system),
            expected
        )
    }

    func testMicrophoneTrackLongerThanSystemTailUsesMicOnly() {
        let mic: [Float] = [0.2, 0.4, 0.6, 0.8]
        let system: [Float] = [0.1, 0.1]

        // index 2/3 have no system sample: mic*1.35 only.
        let expected: [Int16] = [11468, 20316, 26541, 32767]
        XCTAssertEqual(
            RecordingSession.mixFrames(microphoneSamples: mic, systemAudioSamples: system),
            expected
        )
    }

    func testSystemTrackLongerThanMicrophoneTailUsesSystemOnly() {
        let mic: [Float] = [0.3]
        let system: [Float] = [0.3, 0.9, -0.9]

        // index 1/2 have no mic sample: system*0.8 only.
        let expected: [Int16] = [21135, 23592, -23592]
        XCTAssertEqual(
            RecordingSession.mixFrames(microphoneSamples: mic, systemAudioSamples: system),
            expected
        )
    }

    func testExtremesClampToInt16Range() {
        let mic: [Float] = [1.0, -1.0, 0.9]
        let system: [Float] = [1.0, -1.0, 0.9]

        // 1.0*1.35 + 1.0*0.8 = 2.15 -> clamp 1.0 -> 32767, and symmetric negative.
        // index 2: 0.9*2.15 = 1.935 -> clamp 1.0 -> 32767
        let expected: [Int16] = [32767, -32767, 32767]
        XCTAssertEqual(
            RecordingSession.mixFrames(microphoneSamples: mic, systemAudioSamples: system),
            expected
        )
    }

    func testEmptyInputsProduceEmptyOutput() {
        XCTAssertEqual(
            RecordingSession.mixFrames(microphoneSamples: [], systemAudioSamples: []),
            []
        )
    }

    func testOnlyMicrophoneTrackAppliesMicGain() {
        // 0.1*1.35 = 0.135 -> 0.135*32767 = 4423.5 -> 4424 (banker's? .rounded() = away-from-zero)
        let mic: [Float] = [0.1]
        let expected = RecordingSession.mixFrames(microphoneSamples: mic, systemAudioSamples: [])
        // Pin the captured constant (mic-only gain path).
        XCTAssertEqual(expected, [4424])
    }

    /// Pins the Float32 -> Int16 PCM round trip through the same storage layer
    /// production uses, then through the mix seam. This locks the sample format
    /// (32-bit float, little-endian, interleaved mono) that the temp PCM files
    /// use, which the mixdown reads via `TemporaryRecordingPCMStorage.samples`.
    func testPCMStorageRoundTripFeedsMixFormula() {
        let micFloats: [Float] = [0.2, 0.4]
        let systemFloats: [Float] = [0.1, 0.1]

        let micData = micFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let systemData = systemFloats.withUnsafeBufferPointer { Data(buffer: $0) }

        let micSamples = TemporaryRecordingPCMStorage.samples(from: micData)
        let systemSamples = TemporaryRecordingPCMStorage.samples(from: systemData)

        XCTAssertEqual(micSamples, micFloats)
        XCTAssertEqual(systemSamples, systemFloats)

        // 0.2*1.35 + 0.1*0.8 = 0.35 -> 11468 ; 0.4*1.35 + 0.1*0.8 = 0.62 -> 20316
        XCTAssertEqual(
            RecordingSession.mixFrames(microphoneSamples: micSamples, systemAudioSamples: systemSamples),
            [11468, 20316]
        )
    }
}
