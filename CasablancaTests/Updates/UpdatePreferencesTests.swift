import XCTest
@testable import Casablanca

final class UpdatePreferencesTests: XCTestCase {
    private func makeIsolated() -> (UpdatePreferences, UserDefaults) {
        let suite = "test.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (UpdatePreferences(defaults: defaults), defaults)
    }

    func test_defaults() {
        let (prefs, _) = makeIsolated()
        XCTAssertTrue(prefs.automaticChecksEnabled)
        XCTAssertFalse(prefs.includePrereleases)
        XCTAssertNil(prefs.skippedVersion)
        XCTAssertNil(prefs.lastCheckAt)
        XCTAssertFalse(prefs.applicationsLocationPromptShown)
    }

    func test_skippedVersion_roundTrip() throws {
        var (prefs, _) = makeIsolated()
        prefs.skippedVersion = try SemanticVersion(parsing: "0.4.0-beta.1")
        XCTAssertEqual(prefs.skippedVersion, try SemanticVersion(parsing: "0.4.0-beta.1"))
        prefs.skippedVersion = nil
        XCTAssertNil(prefs.skippedVersion)
    }

    func test_lastCheckAt_roundTrip() {
        var (prefs, _) = makeIsolated()
        let now = Date(timeIntervalSince1970: 1_714_550_400)
        prefs.lastCheckAt = now
        XCTAssertEqual(prefs.lastCheckAt, now)
    }

    func test_includePrereleases_andAutomaticChecks_roundTrip() {
        var (prefs, _) = makeIsolated()
        prefs.automaticChecksEnabled = false
        prefs.includePrereleases = true
        XCTAssertFalse(prefs.automaticChecksEnabled)
        XCTAssertTrue(prefs.includePrereleases)
    }
}
