import Foundation

/// Decides whether the Whisper model has to leave memory the moment a
/// transcription ends.
///
/// It used to always leave: summarization runs right after transcription, and a
/// local summarizer (Ollama, oMLX) needs several GB free — with the Whisper
/// model still resident the machine could trip the LLM's own memory guard and
/// fail the request. A CLI provider (Claude Code) holds no model on this Mac,
/// so there unloading buys nothing and costs the next meeting a full model load
/// *plus* prewarm, which WhisperKit runs during load (roughly doubling it).
enum WhisperModelRetentionPolicy {
    /// `true` when the configured summarizer will need the RAM the Whisper
    /// model is holding.
    ///
    /// Switched exhaustively on purpose: a new provider should not silently
    /// inherit either answer.
    static func shouldUnloadAfterTranscription(provider: LLMProviderKind) -> Bool {
        switch provider {
        case .ollama, .omlx:
            return true
        case .claudeCode:
            return false
        }
    }
}

/// Watches for the system running short on memory, so a model kept warm for
/// convenience can still be given back when it actually matters.
///
/// A protocol because memory pressure is real system state: the unit tests
/// drive the seam instead of waiting for the machine to run out of RAM.
protocol MemoryPressureMonitoring: AnyObject {
    /// Starts watching. `handler` runs once per warning or critical event.
    func start(handler: @escaping @Sendable () -> Void)
}

/// The real monitor: a Dispatch memory-pressure source on the main queue.
///
/// It cancels the source in its own `deinit` rather than the owning service's,
/// so the source's lifetime is exactly this object's.
final class DispatchMemoryPressureMonitor: MemoryPressureMonitoring {
    private var source: DispatchSourceMemoryPressure?

    func start(handler: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler(handler: handler)
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
