import XCTest
@testable import Casablanca

@MainActor
final class ExportServiceRoutingTests: XCTestCase {
    private func makeDefaults(suite: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
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
        let vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
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
        case .appleNotes:
            XCTFail("Expected obsidian route")
        }
    }
}
