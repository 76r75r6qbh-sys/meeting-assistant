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

    /// The pipeline and the key it was built with have to disappear together: a
    /// surviving key makes the next load hand back a released pipeline, and a
    /// surviving pipeline is the RAM nobody asked for. `clear()` is the single
    /// place that does it, tested here against a stub because a real `WhisperKit`
    /// cannot be built without downloading a model.
    func testClearingTheCacheDropsThePipelineAndTheKey() {
        var cache = WhisperPipelineCache<StubPipeline>()
        cache.pipeline = StubPipeline()
        cache.key = WhisperPipelineKey(model: "openai_whisper-base", compute: ModelComputeOptions())
        XCTAssertTrue(cache.isLoaded)

        cache.clear()

        XCTAssertNil(cache.pipeline, "The pipeline is the memory being handed back")
        XCTAssertNil(cache.key, "A stale key would make the next load reuse a pipeline that is gone")
        XCTAssertFalse(cache.isLoaded)
        XCTAssertTrue(cache.isEmpty)
    }

    /// What makes the unload-before-load fix necessary: on a key mismatch the
    /// cache still holds the old pipeline, so building the replacement first
    /// would hold two models at once.
    func testCacheOnlyMatchesTheKeyItWasStoredWith() {
        let compute = ModelComputeOptions()
        var cache = WhisperPipelineCache<StubPipeline>()
        let stored = WhisperPipelineKey(model: "openai_whisper-base", compute: compute)
        cache.pipeline = StubPipeline()
        cache.key = stored

        XCTAssertNotNil(cache.pipeline(matching: stored))
        XCTAssertNil(
            cache.pipeline(matching: WhisperPipelineKey(model: "openai_whisper-large-v3", compute: compute)),
            "A different model is a different pipeline"
        )
        XCTAssertNotNil(cache.pipeline, "…and the old one is still resident until it is cleared")
    }

    @MainActor
    func testUnloadModelClearsTheServicesCache() {
        let service = TranscriptionService(memoryPressureMonitor: FakeMemoryPressureMonitor())
        service.primeCachedPipelineKeyForTesting(
            WhisperPipelineKey(model: "openai_whisper-base", compute: ModelComputeOptions())
        )
        XCTAssertNotNil(service.cachedPipelineKeyForTesting)

        service.unloadModel()

        XCTAssertNil(service.cachedPipelineKeyForTesting)
        XCTAssertTrue(service.cacheIsEmptyForTesting)
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
    func testFiringTheMonitorReachesTheService() async {
        let monitor = FakeMemoryPressureMonitor()
        let service = TranscriptionService(memoryPressureMonitor: monitor)
        service.primeCachedPipelineKeyForTesting(
            WhisperPipelineKey(model: "openai_whisper-base", compute: ModelComputeOptions())
        )

        monitor.fire()

        // The handler hops to the main actor through a weak reference, which is
        // the wiring under test — let that Task run before asserting.
        for _ in 0..<100 where service.cachedPipelineKeyForTesting != nil {
            await Task.yield()
        }
        XCTAssertNil(
            service.cachedPipelineKeyForTesting,
            "A pressure event has to reach handleMemoryPressure, not just be subscribed to"
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
    private var handler: (@Sendable () -> Void)?

    var isStarted: Bool { handler != nil }

    func start(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler?()
    }
}

/// Stands in for the pipeline the cache holds: `WhisperKit` itself cannot be
/// constructed without downloading and loading a model.
private final class StubPipeline {}
