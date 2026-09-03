import CoreML
import WhisperKit
import XCTest
@testable import Casablanca

final class TranscriptionOptionsBuilderTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TranscriptionOptionsBuilderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults equal today's behaviour

    func testDefaultsForDutch() {
        let resolved = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults)
        let decoding = resolved.decoding

        XCTAssertEqual(decoding.language, "nl")
        XCTAssertEqual(decoding.temperature, 0)
        XCTAssertEqual(decoding.task, .transcribe)
        XCTAssertTrue(decoding.skipSpecialTokens)
        XCTAssertFalse(decoding.wordTimestamps)
        XCTAssertFalse(decoding.withoutTimestamps)
        XCTAssertEqual(decoding.temperatureFallbackCount, 5)
        XCTAssertEqual(decoding.concurrentWorkerCount, 16)
        XCTAssertEqual(decoding.compressionRatioThreshold, 2.4)
        XCTAssertEqual(decoding.logProbThreshold, -1.0)
        XCTAssertEqual(decoding.firstTokenLogProbThreshold, -1.5)
        XCTAssertEqual(decoding.noSpeechThreshold, 0.6)
        XCTAssertEqual(decoding.chunkingStrategy, .vad)
        XCTAssertFalse(resolved.dropSilentChunks)
        XCTAssertEqual(resolved.silentChunkEnergyThreshold, 0.02)
    }

    func testComputeDefaults() {
        let compute = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).compute

        XCTAssertEqual(compute.melCompute, .cpuAndGPU)
        XCTAssertEqual(compute.audioEncoderCompute, .cpuAndNeuralEngine)
        XCTAssertEqual(compute.textDecoderCompute, .cpuAndNeuralEngine)
        XCTAssertEqual(compute.prefillCompute, .cpuOnly)
    }

    // MARK: - Overrides

    func testComputeOverrideFromDefaults() {
        defaults.set("gpu", forKey: "whisperDecoderCompute")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).compute.textDecoderCompute,
            .cpuAndGPU
        )

        defaults.set("cpu", forKey: "whisperEncoderCompute")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).compute.audioEncoderCompute,
            .cpuOnly
        )

        defaults.set("bogus", forKey: "whisperDecoderCompute")
        defaults.set("bogus", forKey: "whisperEncoderCompute")
        let fallenBack = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).compute
        XCTAssertEqual(fallenBack.textDecoderCompute, .cpuAndNeuralEngine)
        XCTAssertEqual(fallenBack.audioEncoderCompute, .cpuAndNeuralEngine)
    }

    func testFallbackCountOverrideClampedToZeroOrMore() {
        defaults.set(2, forKey: "whisperFallbackCount")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).decoding.temperatureFallbackCount,
            2
        )

        defaults.set(0, forKey: "whisperFallbackCount")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).decoding.temperatureFallbackCount,
            0
        )

        defaults.set(-3, forKey: "whisperFallbackCount")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).decoding.temperatureFallbackCount,
            0
        )
    }

    func testWorkersOverrideIgnoresZeroAndNegative() {
        defaults.set(4, forKey: "whisperWorkers")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).decoding.concurrentWorkerCount,
            4
        )

        defaults.set(0, forKey: "whisperWorkers")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).decoding.concurrentWorkerCount,
            16
        )

        defaults.set(-1, forKey: "whisperWorkers")
        XCTAssertEqual(
            TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).decoding.concurrentWorkerCount,
            16
        )
    }

    func testLogProbAndCompressionThresholdOverrides() {
        defaults.set(-0.5, forKey: "whisperLogProbThreshold")
        defaults.set(1.8, forKey: "whisperCompressionRatioThreshold")

        let decoding = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).decoding
        XCTAssertEqual(decoding.logProbThreshold, -0.5)
        XCTAssertEqual(decoding.compressionRatioThreshold, 1.8)
        // Not tunable in this task, so it must keep WhisperKit's default.
        XCTAssertEqual(decoding.firstTokenLogProbThreshold, -1.5)
    }

    func testChunkingStrategyNilWhenDroppingSilence() {
        defaults.set(true, forKey: "whisperDropSilentChunks")
        defaults.set(0.05, forKey: "whisperSilentChunkEnergy")

        let resolved = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults)
        XCTAssertTrue(resolved.dropSilentChunks)
        XCTAssertEqual(resolved.silentChunkEnergyThreshold, 0.05)
        XCTAssertNil(resolved.decoding.chunkingStrategy)
    }

    // MARK: - Summary line

    func testSummaryLineContainsEveryTunable() {
        let summary = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).summaryLine

        for expected in [
            "lang=nl",
            "temp=0",
            "fallbacks=5",
            "workers=16",
            "logProb=-1",
            "compression=2.4",
            "chunking=vad",
            "mel=gpu",
            "enc=ane",
            "dec=ane",
            "prefill=cpu",
            "dropSilent=false",
            "silentEnergy=0.02",
            "skipSpecialTokens=true",
        ] {
            XCTAssertTrue(summary.contains(expected), "summary line is missing \(expected): \(summary)")
        }
    }

    func testSummaryLineReflectsOverrides() {
        defaults.set("gpu", forKey: "whisperDecoderCompute")
        defaults.set(3, forKey: "whisperWorkers")
        defaults.set(true, forKey: "whisperDropSilentChunks")

        let summary = TranscriptionOptionsBuilder.resolve(language: "en", defaults: defaults).summaryLine

        XCTAssertTrue(summary.contains("lang=en"), summary)
        XCTAssertTrue(summary.contains("dec=gpu"), summary)
        XCTAssertTrue(summary.contains("workers=3"), summary)
        XCTAssertTrue(summary.contains("dropSilent=true"), summary)
        XCTAssertTrue(summary.contains("chunking=none"), summary)
    }

    // MARK: - Resolved equality and the pipeline cache key

    func testResolvedIsEquatableAcrossIdenticalResolutions() {
        let first = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults)
        let second = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults)
        XCTAssertEqual(first, second)

        defaults.set("cpu", forKey: "whisperDecoderCompute")
        let changed = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults)
        XCTAssertNotEqual(first, changed)
    }

    func testPipelineKeyDistinguishesModelAndCompute() {
        let compute = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).compute
        defaults.set("cpu", forKey: "whisperEncoderCompute")
        let cpuCompute = TranscriptionOptionsBuilder.resolve(language: "nl", defaults: defaults).compute

        let base = WhisperPipelineKey(model: "openai_whisper-small", compute: compute)
        XCTAssertEqual(base, WhisperPipelineKey(model: "openai_whisper-small", compute: compute))
        XCTAssertNotEqual(base, WhisperPipelineKey(model: "openai_whisper-base", compute: compute))
        XCTAssertNotEqual(base, WhisperPipelineKey(model: "openai_whisper-small", compute: cpuCompute))
    }
}
