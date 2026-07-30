import Foundation
import XCTest
@testable import Casablanca

/// Unit tests for the Dock-badge formatter. We intentionally do NOT assert on
/// `NSApp.dockTile` (flaky / unavailable in the test host); the formatter is the
/// testable seam and `apply(count:)` just forwards `label(for:)`.
final class DockBadgeTests: XCTestCase {
    func testLabelIsNilAtZero() {
        XCTAssertNil(DockBadge.label(for: 0))
    }

    func testLabelForSingle() {
        XCTAssertEqual(DockBadge.label(for: 1), "1")
    }

    func testLabelForSeven() {
        XCTAssertEqual(DockBadge.label(for: 7), "7")
    }
}
