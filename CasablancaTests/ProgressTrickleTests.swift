import Foundation
import XCTest
@testable import Casablanca

/// Covers the pure creep math used to keep the transcription progress bar
/// visibly moving between real checkpoints (see `TranscriptionService`'s
/// progress ticker).
final class ProgressTrickleTests: XCTestCase {

    func testEasesTowardCheckpointPlusBudgetNotAllTheWayThere() {
        let next = ProgressTrickle.next(current: 0.05, checkpoint: 0.05, budget: 0.04, ceiling: 0.95, easing: 0.25)
        // Target is 0.09; easing 25% of the way there from 0.05.
        XCTAssertEqual(next, 0.05 + (0.09 - 0.05) * 0.25, accuracy: 0.0001)
        XCTAssertLessThan(next, 0.09)
    }

    func testHoldsOnceCurrentReachesTarget() {
        let next = ProgressTrickle.next(current: 0.09, checkpoint: 0.05, budget: 0.04, ceiling: 0.95, easing: 0.25)
        XCTAssertEqual(next, 0.09, accuracy: 0.0001)
    }

    func testNeverExceedsCeilingRegardlessOfCheckpoint() {
        let next = ProgressTrickle.next(current: 0.90, checkpoint: 0.93, budget: 0.10, ceiling: 0.95, easing: 1.0)
        XCTAssertLessThanOrEqual(next, 0.95)
    }

    func testDoesNotMoveBackwardWhenCurrentAlreadyPastTarget() {
        // A real checkpoint jumped `current` ahead of what checkpoint+budget
        // would suggest (e.g. a fast VAD update) — trickle must never pull it back.
        let next = ProgressTrickle.next(current: 0.5, checkpoint: 0.1, budget: 0.04, ceiling: 0.95, easing: 0.25)
        XCTAssertEqual(next, 0.5)
    }

    func testRepeatedTicksConvergeTowardTargetWithoutOvershooting() {
        var value = 0.05
        for _ in 0..<100 {
            value = ProgressTrickle.next(current: value, checkpoint: 0.05, budget: 0.04, ceiling: 0.95, easing: 0.25)
        }
        XCTAssertEqual(value, 0.09, accuracy: 0.001)
    }

    func testHigherCheckpointRaisesTheTargetImmediately() {
        // Already sitting exactly at the old checkpoint's target — holds.
        let atOldTarget = ProgressTrickle.next(current: 0.09, checkpoint: 0.05, budget: 0.04, ceiling: 0.95, easing: 0.25)
        XCTAssertEqual(atOldTarget, 0.09, accuracy: 0.0001)

        // A real VAD update landing mid-trickle should let subsequent ticks
        // keep climbing toward the new, higher checkpoint.
        let afterNewCheckpoint = ProgressTrickle.next(current: 0.09, checkpoint: 0.30, budget: 0.04, ceiling: 0.95, easing: 0.25)
        XCTAssertGreaterThan(afterNewCheckpoint, 0.09)
    }
}
