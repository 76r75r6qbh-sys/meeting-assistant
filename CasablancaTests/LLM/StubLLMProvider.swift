import Foundation
@testable import Casablanca

/// `LLMProvider` double that records what each call was handed and replays canned
/// outcomes in order.
///
/// It exists so a *service's* wiring can be asserted — which timeout it chooses,
/// whether it calls the provider at all, what it shows the user between retries —
/// without a live backend and without the real providers' transport concerns.
///
/// `@unchecked Sendable`: the recording lives behind a lock, and the capability
/// values are immutable.
final class StubLLMProvider: LLMProvider, @unchecked Sendable {
    struct Call: Sendable {
        let prompt: String
        let temperature: Double?
        let maxTokens: Int?
        let timeout: TimeInterval
    }

    let displayName: String
    let endpoint: String
    let preferredTimeout: TimeInterval?
    let supportsFullTranscriptEcho: Bool
    let promptTokenBudget: Int

    /// Run on the main actor at the start of every `generate`, so a test can observe
    /// service state *mid-flight* (the retry status message, say) rather than only
    /// the state left behind once everything settled.
    private let onGenerate: (@MainActor @Sendable () -> Void)?

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    /// Consumed one per `generate`; the last one repeats once they run out, so a
    /// test that only cares about the happy path can pass a single outcome.
    private var outcomes: [Result<String, Error>]
    /// What each `generate` reports through its `truncated` closure, consumed in
    /// step with `outcomes` (the last one repeats). Empty means never truncated.
    private var truncatedFlags: [Bool]

    init(
        displayName: String = "Stub",
        endpoint: String = "stub://endpoint",
        preferredTimeout: TimeInterval? = nil,
        supportsFullTranscriptEcho: Bool = true,
        promptTokenBudget: Int = LLMPromptSupport.localPromptTokenBudget,
        outcomes: [Result<String, Error>] = [.success("stub output")],
        truncatedFlags: [Bool] = [],
        onGenerate: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.displayName = displayName
        self.endpoint = endpoint
        self.preferredTimeout = preferredTimeout
        self.supportsFullTranscriptEcho = supportsFullTranscriptEcho
        self.promptTokenBudget = promptTokenBudget
        self.truncatedFlags = truncatedFlags
        self.outcomes = outcomes.isEmpty ? [.success("stub output")] : outcomes
        self.onGenerate = onGenerate
    }

    var calls: [Call] { lock.withLock { recordedCalls } }

    func generate(
        prompt: String,
        temperature: Double?,
        maxTokens: Int?,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String {
        if let onGenerate { await onGenerate() }
        let (outcome, wasTruncated): (Result<String, Error>, Bool) = lock.withLock {
            recordedCalls.append(
                Call(prompt: prompt, temperature: temperature, maxTokens: maxTokens, timeout: timeout)
            )
            let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
            let flag: Bool
            if truncatedFlags.isEmpty {
                flag = false
            } else {
                flag = truncatedFlags.count > 1 ? truncatedFlags.removeFirst() : truncatedFlags[0]
            }
            return (outcome, flag)
        }
        // Like the real providers: the flag is only reported for a returned answer.
        let text = try outcome.get()
        truncated?(wasTruncated)
        return text
    }

    func fetchAvailableModels(endpoint: String) async throws -> [String] {
        ["stub-model"]
    }

    /// A transient failure, so `LLMRetryPolicy` reruns the call.
    static func transientFailure() -> Error {
        LLMProviderError.requestFailed(provider: "Stub", kind: .network(.timedOut), message: "stub timeout")
    }
}
