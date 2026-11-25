import XCTest
@testable import Casablanca

@MainActor
final class AppleNotesMeetingExporterTests: XCTestCase {
    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Notes."
        meeting.summary = "Summary."
        return meeting
    }

    func testFirstExportCreatesFolderAndBothNotes() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        let result = try await exporter.export(meeting)

        let folders = await fake.folders
        XCTAssertEqual(folders.map(\.name), ["Casablanca"])
        let notes = await fake.notes
        XCTAssertEqual(notes.count, 2)
        XCTAssertNotNil(result.summaryNoteId)
        XCTAssertNotNil(result.rawNotesNoteId)
        XCTAssertEqual(meeting.appleNotesSummaryNoteID, result.summaryNoteId)
        XCTAssertEqual(meeting.appleNotesRawNotesNoteID, result.rawNotesNoteId)
    }

    func testReExportUpdatesExistingNotesAndDoesNotDuplicate() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        _ = try await exporter.export(meeting)
        meeting.summary = "Updated summary."
        _ = try await exporter.export(meeting)

        let notes = await fake.notes
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.body.contains("Updated summary.") })
    }

    func testReExportAfterClearedCacheFallsBackToMarkerScan() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        _ = try await exporter.export(meeting)
        let originalNoteCount = await fake.notes.count
        meeting.appleNotesSummaryNoteID = nil
        meeting.appleNotesRawNotesNoteID = nil

        _ = try await exporter.export(meeting)

        let finalCount = await fake.notes.count
        XCTAssertEqual(originalNoteCount, 2)
        XCTAssertEqual(finalCount, 2, "Marker scan should reuse existing notes")
        XCTAssertNotNil(meeting.appleNotesSummaryNoteID, "Resolved id should be written back")
    }

    func testStaleCachedIdPointingToUnrelatedNoteForcesScan() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()
        _ = try await exporter.export(meeting)

        // Simulate id drift: cached id now points at a body without the meeting's marker.
        let cachedId = meeting.appleNotesSummaryNoteID!
        try await fake.updateNote(id: cachedId, title: "Stranger", body: "<p>unrelated</p>")

        _ = try await exporter.export(meeting)

        let notes = await fake.notes
        // The unrelated note must still exist with its body intact: the exporter must NOT
        // overwrite it just because the cache pointed at it.
        XCTAssertTrue(notes.contains { $0.id == cachedId && $0.body == "<p>unrelated</p>" },
            "Stale cache must not overwrite the unrelated note")
        // After the stale-cache fallback, the exporter creates a fresh summary note (marker scan
        // returns nil because the marker-bearing summary was overwritten by the test setup).
        XCTAssertEqual(notes.count, 3, "Expected: original raw notes + stranger + new summary")
        // The cached id was updated to the new note.
        XCTAssertNotEqual(meeting.appleNotesSummaryNoteID, cachedId)
        XCTAssertNotNil(meeting.appleNotesSummaryNoteID)
        // And the new note carries the meeting's marker.
        let summaryMarker = "Casablanca id: \(meeting.id.uuidString) / summary"
        XCTAssertTrue(notes.contains { $0.id == meeting.appleNotesSummaryNoteID && $0.body.contains(summaryMarker) })
    }

    func testNameLookupRecoversWhenMarkerIsStrippedFromBody() async throws {
        // Real-world scenario: after the first export, Apple Notes stores the body in its own
        // canonical HTML form, sometimes mangling or stripping the embedded marker. On the next
        // export the cached id may also have drifted (Apple Notes re-issues note ids on sync).
        // Without a name-based fallback the exporter would treat this as "not found" and create
        // a duplicate. We verify the name lookup recovers the existing note instead.
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()
        _ = try await exporter.export(meeting)

        // Simulate Notes' body mangling: keep the note title and id but wipe the marker.
        let summaryId = meeting.appleNotesSummaryNoteID!
        let rawId = meeting.appleNotesRawNotesNoteID!
        try await fake.updateNote(id: summaryId, title: meeting.obsidianFileName, body: "<p>marker mysteriously gone</p>")
        try await fake.updateNote(id: rawId, title: "\(meeting.obsidianFileName) - Notes", body: "<p>marker mysteriously gone</p>")

        // Clear the cached ids to simulate post-sync drift.
        meeting.appleNotesSummaryNoteID = nil
        meeting.appleNotesRawNotesNoteID = nil

        _ = try await exporter.export(meeting)

        let notes = await fake.notes
        XCTAssertEqual(notes.count, 2,
            "Name lookup should reuse the existing two notes, not create duplicates; got count=\(notes.count) with bodies=\(notes.map(\.body))")
        // The cached ids should now point back at the same notes.
        XCTAssertEqual(meeting.appleNotesSummaryNoteID, summaryId)
        XCTAssertEqual(meeting.appleNotesRawNotesNoteID, rawId)
        // And the bodies should be fresh (no longer the stripped placeholder).
        XCTAssertTrue(notes.allSatisfy { $0.body.contains("Casablanca id:") })
    }

    func testFolderDeletedOutOfBandIsRecreated() async throws {
        let fake = InMemoryAppleNotesScripting()
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()
        _ = try await exporter.export(meeting)

        await fake.removeFolder(named: "Casablanca")
        let emptyFolderCount = await fake.folders.count
        XCTAssertEqual(emptyFolderCount, 0)

        _ = try await exporter.export(meeting)

        let folderCount = await fake.folders.count
        let noteCount = await fake.notes.count
        XCTAssertEqual(folderCount, 1)
        XCTAssertEqual(noteCount, 2)
    }

    func testPermissionDeniedErrorPropagatesAsExportError() async throws {
        let fake = InMemoryAppleNotesScripting()
        await fake.setEnsureFolderError(NSError(
            domain: "NSAppleScriptErrorDomain",
            code: 0,
            userInfo: ["NSAppleScriptErrorNumber": -1743]
        ))
        let exporter = AppleNotesMeetingExporter(scripting: fake)
        let meeting = makeMeeting()

        do {
            _ = try await exporter.export(meeting)
            XCTFail("Expected throw")
        } catch let error as AppleNotesExportError {
            XCTAssertEqual(error, .permissionDenied)
        }
    }
}
