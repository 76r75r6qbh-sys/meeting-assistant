import XCTest
@testable import Casablanca

final class MeetingPrepServiceWriteTests: XCTestCase {
    func test_writesPrepToVaultThenReadsBack() throws {
        let tmp = makeScratchVault("prep-write")
        let defaults = makeScratchDefaults(vaultRoot: tmp, label: "prep-write")
        defaults.set(PrepTodoStorage.obsidian.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        assertScratchVault(defaults)

        let m = Meeting(title: "Daily standup",
                        date: ISO8601DateFormatter().date(from: "2026-05-30T11:00:00Z")!)
        try MeetingPrepService.writePrep("## Goal\nAlign on BgZ.", for: m, userDefaults: defaults)
        let read = MeetingPrepService.loadPrepMarkdown(for: m, userDefaults: defaults)
        XCTAssertEqual(read?.contains("Align on BgZ."), true)
    }

    func test_localOnlyModeStoresOnMeeting() throws {
        let defaults = makeScratchDefaults(label: "prep-local")
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let m = Meeting(title: "Sync", date: .now)
        try MeetingPrepService.writePrep("notes", for: m, userDefaults: defaults)
        XCTAssertEqual(m.localPrepNotes, "notes")
    }
}
