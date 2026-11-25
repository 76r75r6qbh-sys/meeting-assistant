import XCTest
@testable import Casablanca

@MainActor
final class ExportServiceRoutingTests: XCTestCase {
    /// A throwaway preference domain — never the standard one, which in this
    /// test host is the user's own (see `TestVaultGuard`).
    private func makeDefaults() -> UserDefaults {
        makeScratchDefaults(label: "export-routing")
    }

    func testRoutesToAppleNotesWhenDestinationSelected() async throws {
        let defaults = makeDefaults()
        defaults.set(ExportDestination.appleNotes.rawValue, forKey: AppPreferenceKey.exportDestination)
        let scripting = InMemoryAppleNotesScripting()
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Notes"
        meeting.summary = "Summary"

        let result = try await ExportService.exportCompletedMeeting(
            meeting,
            defaults: defaults,
            appleNotesScripting: scripting
        )

        switch result {
        case .appleNotes(let summaryId, let notesId):
            XCTAssertNotNil(summaryId)
            XCTAssertFalse(notesId.isEmpty)
            let notes = await scripting.notes
            XCTAssertEqual(notes.count, 2)
        case .obsidian:
            XCTFail("Expected appleNotes route")
        }
    }

    func testRoutesToObsidianByDefault() async throws {
        let defaults = makeDefaults()
        let vaultURL = makeScratchVault("export-routing")
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Notes"
        meeting.summary = "Summary"

        let result = try await ExportService.exportCompletedMeeting(
            meeting,
            defaults: defaults,
            appleNotesScripting: InMemoryAppleNotesScripting()
        )

        switch result {
        case .obsidian(let export):
            XCTAssertNotNil(export.summaryURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: export.notesURL.path))
            // The exporter must honour the injected defaults, not the user's
            // real preference domain: this is exactly how full-suite runs wrote
            // `2023-11-14 Sync.md` into the real vault.
            TestVaultGuard.assertTemporary(export.notesURL, "exported notes file")
            TestVaultGuard.assertTemporaryIfPresent(export.summaryURL, "exported summary file")
        case .appleNotes:
            XCTFail("Expected obsidian route")
        }
    }
}
