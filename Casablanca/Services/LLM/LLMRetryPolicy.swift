import Foundation

/// Retries a transient LLM operation with exponential backoff and jitter.
///
/// Only `LLMProviderError`s whose `isTransient` is `true` are retried (network
/// blips, 5xx/408/429); everything else is rethrown immediately. Cancellation is
/// honored between attempts, so cancelling during a backoff sleep aborts cleanly.
struct LLMRetryPolicy {
    /// Total attempts including the first try (so `3` means: try once, then up to
    /// two retries).
    let maxAttempts: Int
    /// Base backoff in seconds; the delay before the Nth retry is
    /// `baseDelay * 2^(attempt-1)` with ±20% jitter applied.
    let baseDelay: TimeInterval

    /// Sleep seam, in seconds. Injectable so tests run instantly instead of
    /// actually waiting. Defaults to `Task.sleep`.
    private let sleep: (TimeInterval) async throws -> Void

    init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.sleep = sleep
    }

    /// Runs `operation`, retrying transient failures with backoff.
    /// - Parameters:
    ///   - onAttempt: Called with the attempt number (1-based) just before each
    ///     retry attempt (i.e. for attempts 2…maxAttempts), so callers can surface
    ///     "retrying" UI. Not called before the first attempt.
    ///   - operation: The work to perform; rerun on transient failure.
    func withRetry<T>(
        onAttempt: (Int) -> Void = { _ in },
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as LLMProviderError where error.isTransient && attempt < maxAttempts {
                // Backoff before the next attempt; bail immediately if cancelled.
                let delay = backoffDelay(forAttempt: attempt)
                try await sleep(delay)
                try Task.checkCancellation()
                attempt += 1
                onAttempt(attempt)
            }
            // Non-transient errors, or the final attempt's failure, propagate out
            // of the do/catch (no matching catch) and are rethrown to the caller.
        }
    }

    /// `baseDelay * 2^(attempt-1)` with ±20% multiplicative jitter.
    private func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0.8...1.2)
        return exponential * jitter
    }
}
