import WhisperKit
import XCTest
@testable import Casablanca

/// Unloading the Whisper model after every transcription exists to free RAM for
/// a *local* summarizer. With a CLI provider there is no local model to make
/// room for, so the unload only re-pays load + prewarm on the next meeting.
final class WhisperModelRetentionPolicyTests: XCTestCase {
    // MARK: - Policy

    func testLocalProvidersUnloadAfterTranscription() {
        XCTAssertTrue(
            WhisperModelRetentionPolicy.shouldUnloadAfterTranscription(provider: .ollama),
            "Ollama holds several GB locally; the Whisper model has to give the RAM back"
        )
        XCTAssertTrue(
            WhisperModelRetentionPolicy.shouldUnloadAfterTranscription(provider: .omlx),
            "oMLX holds several GB locally; the Whisper model has to give the RAM back"
        )
    }

    func testClaudeCodeKeepsTheModelLoaded() {
        XCTAssertFalse(
            WhisperModelRetentionPolicy.shouldUnloadAfterTranscription(provider: .claudeCode),
            "The Claude Code CLI needs no local model RAM, so keep Whisper warm for the next meeting"
        )
    }

    // MARK: - Cache teardown

    @MainActor
    func testUnloadModelClearsPipelineAndCacheKey() {
        let service = TranscriptionService(memoryPressureMonitor: FakeMemoryPressureMonitor())
        service.primeCachedPipelineKeyForTesting(
            WhisperPipelineKey(model: "openai_whisper-base", compute: ModelComputeOptions())
        )
        XCTAssertNotNil(service.cachedPipelineKeyForTesting)

        service.unloadModel()

        XCTAssertNil(
            service.cachedPipelineKeyForTesting,
            "A stale key would make the next load reuse a pipeline that no longer exists"
        )
        XCTAssertFalse(service.hasCachedPipelineForTesting)
    }

    // MARK: - Memory pressure

    @MainActor
    func testMemoryPressureUnloadsTheIdleModel() {
        let monitor = FakeMemoryPressureMonitor()
        let service = TranscriptionService(memoryPressureMonitor: monitor)
        service.primeCachedPipelineKeyForTesting(
            WhisperPipelineKey(model: "openai_whisper-base", compute: ModelComputeOptions())
        )

        XCTAssertTrue(monitor.isStarted, "The service has to be watching for pressure to react to it")
        service.handleMemoryPressure()

        XCTAssertNil(
            service.cachedPipelineKeyForTesting,
            "Keeping the model warm is a convenience; the system needing RAM outranks it"
        )
    }

    @MainActor
    func testMemoryPressureDuringATranscriptionKeepsTheModel() {
        let service = TranscriptionService(memoryPressureMonitor: FakeMemoryPressureMonitor())
        service.primeCachedPipelineKeyForTesting(
            WhisperPipelineKey(model: "openai_whisper-base", compute: ModelComputeOptions())
        )
        service.isTranscribing = true

        service.handleMemoryPressure()

        XCTAssertNotNil(
            service.cachedPipelineKeyForTesting,
            "Pulling the pipeline out from under a running decode would fail the transcription"
        )
    }
}

/// Memory pressure is real system state, so the unit tests drive the seam
/// instead of waiting for the machine to run short of RAM.
private final class FakeMemoryPressureMonitor: MemoryPressureMonitoring {
    private(set) var isStarted = false

    func start(handler: @escaping @Sendable () -> Void) {
        isStarted = true
    }
}
