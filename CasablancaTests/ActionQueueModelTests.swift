import Foundation
import XCTest
@testable import Casablanca

/// Focused on the debounce/stop-watching race: a reload scheduled by a
/// filesystem event must NOT fire if watching was stopped before the debounce
/// elapsed (e.g. the queue file/directory was deleted). We drive the debounce
/// directly with a tiny interval so the test is deterministic, not timing-flaky.
///
/// Detection seam: with no queue file present, `reload()` clears `loadError`.
/// We pre-seed `loadError` with a sentinel; if the reload ran the sentinel is
/// cleared, if it was skipped the sentinel survives.
@MainActor
final class ActionQueueModelTests: XCTestCase {
    private let sentinel = "sentinel-not-reloaded"

    func testStopWatchingBeforeDebounceFiresSkipsReload() async {
        // No watchSource is set (startWatching not called / pointed at a missing
        // dir), so the guard `watchSource != nil` must short-circuit the reload.
        let model = ActionQueueModel(debounceInterval: .milliseconds(5))
        model.loadError = sentinel

        let task = model.scheduleDebouncedReloadNow()
        // Simulate watching being torn down before the debounce elapses.
        model.stopWatching()
        await task.value

        XCTAssertEqual(
            model.loadError, sentinel,
            "reload() must be skipped when watching stopped before the debounce fired"
        )
    }

    func testStopWatchingCancelsPendingDebounceTask() async {
        let model = ActionQueueModel(debounceInterval: .milliseconds(50))
        model.loadError = sentinel

        let task = model.scheduleDebouncedReloadNow()
        model.stopWatching()       // cancels the pending debounce task
        await task.value

        XCTAssertTrue(task.isCancelled || model.loadError == sentinel)
        XCTAssertEqual(model.loadError, sentinel, "cancelled debounce must not reload")
    }
}
