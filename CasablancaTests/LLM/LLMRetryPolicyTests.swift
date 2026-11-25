import XCTest
@testable import Casablanca

final class LLMRetryPolicyTests: XCTestCase {
    /// Sleep seam that records each requested delay and returns instantly, so the
    /// suite never actually waits.
    private final class SleepSpy: @unchecked Sendable {
        private(set) var delays: [TimeInterval] = []
        func sleep(_ seconds: TimeInterval) async throws { delays.append(seconds) }
    }

    private func transientError() -> LLMProviderError {
        .requestFailed(provider: "Test", kind: .httpStatus(500), message: "boom")
    }

    private func nonTransientError() -> LLMProviderError {
        .requestFailed(provider: "Test", kind: .httpStatus(400), message: "bad request")
    }

    func testTransientRetriedUpToMaxAttemptsThenRethrows() async {
        let spy = SleepSpy()
        let policy = LLMRetryPolicy(maxAttempts: 3, baseDelay: 1.0, sleep: spy.sleep)
        var calls = 0
        var attempts: [Int] = []

        await XCTAssertThrowsErrorAsync(
            try await policy.withRetry(onAttempt: { attempts.append($0) }) {
                calls += 1
                throw self.transientError()
            }
        ) { error in
            guard case LLMProviderError.requestFailed = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
        }

        XCTAssertEqual(calls, 3, "should try exactly maxAttempts times")
        XCTAssertEqual(attempts, [2, 3], "onAttempt fires before retries 2 and 3")
        XCTAssertEqual(spy.delays.count, 2, "two backoff sleeps for two retries")
    }

    func testTransientThenSuccessReturnsResult() async throws {
        let spy = SleepSpy()
        let policy = LLMRetryPolicy(maxAttempts: 3, baseDelay: 1.0, sleep: spy.sleep)
        var calls = 0
        var attempts: [Int] = []

        let result = try await policy.withRetry(onAttempt: { attempts.append($0) }) { () -> String in
            calls += 1
            if calls < 2 { throw self.transientError() }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(attempts, [2], "onAttempt called once, with the second attempt number")
        XCTAssertEqual(spy.delays.count, 1)
    }

    func testNonTransientThrownImmediatelyWithoutRetry() async {
        let spy = SleepSpy()
        let policy = LLMRetryPolicy(maxAttempts: 3, baseDelay: 1.0, sleep: spy.sleep)
        var calls = 0
        var attempts: [Int] = []

        await XCTAssertThrowsErrorAsync(
            try await policy.withRetry(onAttempt: { attempts.append($0) }) {
                calls += 1
                throw self.nonTransientError()
            }
        ) { error in
            guard case LLMProviderError.requestFailed(_, let kind, _) = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
            XCTAssertEqual(kind, .httpStatus(400))
        }

        XCTAssertEqual(calls, 1, "non-transient must not be retried")
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertTrue(spy.delays.isEmpty, "no backoff for non-transient failures")
    }

    func testCancellationDuringBackoffThrowsAndStops() async {
        // Sleep seam that cancels the surrounding task mid-backoff, then returns.
        // The policy's `Task.checkCancellation()` after the sleep should abort.
        let policy = LLMRetryPolicy(maxAttempts: 5, baseDelay: 1.0, sleep: { _ in })
        var calls = 0

        let task = Task { () -> String in
            try await policy.withRetry {
                calls += 1
                // Cancel ourselves before the next backoff completes.
                withUnsafeCurrentTask { $0?.cancel() }
                throw self.transientError()
            }
        }

        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected cancellation to abort the retry loop")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertEqual(calls, 1, "loop stops after cancellation, no further attempts")
    }
}
