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

    // MARK: - onPendingCountChange (Dock/menu-bar badge driver)

    /// `reload()` reads `UserDefaults.standard` for the queue path, so point the
    /// standard key at a temp file for the duration of the test and restore it
    /// afterwards. Mirrors the store tests' temp-file fixture approach.
    func testOnPendingCountChangeFiresWithPendingCountOnReload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActionQueueModelTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let queueURL = tempDir.appendingPathComponent("action-queue.json")
        // 3 pending + 2 non-pending (declined / completed). pendingCount == 3.
        let json = """
        {
          "version": 1,
          "items": [
            { "id": "AQ-1", "title": "p1", "status": "pending" },
            { "id": "AQ-2", "title": "p2", "status": "pending" },
            { "id": "AQ-3", "title": "p3", "status": "pending" },
            { "id": "AQ-4", "title": "d1", "status": "declined" },
            { "id": "AQ-5", "title": "c1", "status": "completed" }
          ]
        }
        """
        try json.write(to: queueURL, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AppPreferenceKey.actionQueuePath)
        defaults.set(queueURL.path, forKey: AppPreferenceKey.actionQueuePath)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferenceKey.actionQueuePath)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.actionQueuePath)
            }
        }

        let model = ActionQueueModel()
        var captured: Int?
        model.onPendingCountChange = { captured = $0 }

        model.reload()

        XCTAssertNil(model.loadError, "fixture should load cleanly")
        XCTAssertEqual(model.pendingCount, 3)
        XCTAssertEqual(captured, 3, "onPendingCountChange must fire on reload with the pending count")

        // Error path: a malformed file must still fire the callback with the
        // last-good count (items unchanged) so the badge never goes stale.
        try "{ not valid json".write(to: queueURL, atomically: true, encoding: .utf8)
        captured = nil
        model.reload()

        XCTAssertNotNil(model.loadError, "malformed JSON should set loadError")
        XCTAssertEqual(model.pendingCount, 3, "items unchanged on load failure")
        XCTAssertEqual(captured, 3, "callback must fire with the last-good count on error")
    }
}
