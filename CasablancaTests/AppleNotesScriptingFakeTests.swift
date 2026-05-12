import XCTest
@testable import Casablanca

final class AppleNotesScriptingFakeTests: XCTestCase {
    func testEnsureFolderIsIdempotent() async throws {
        let fake = InMemoryAppleNotesScripting()
        let first = try await fake.ensureFolder(named: "Casablanca")
        let second = try await fake.ensureFolder(named: "Casablanca")
        XCTAssertEqual(first.id, second.id)
        let folderCount = await fake.folders.count
        XCTAssertEqual(folderCount, 1)
    }

    func testCreateNotePersistsAndReturnsRef() async throws {
        let fake = InMemoryAppleNotesScripting()
        let folder = try await fake.ensureFolder(named: "Casablanca")
        let ref = try await fake.createNote(title: "Hello", body: "<html><body><p>hi</p></body></html>", in: folder)
        XCTAssertFalse(ref.id.isEmpty)
        let body = try await fake.noteBody(id: ref.id)
        XCTAssertEqual(body, "<html><body><p>hi</p></body></html>")
    }

    func testFindNoteMatchesMarkerSubstring() async throws {
        let fake = InMemoryAppleNotesScripting()
        let folder = try await fake.ensureFolder(named: "Casablanca")
        _ = try await fake.createNote(title: "A", body: "<p>Casablanca id: 11111111-1111-1111-1111-111111111111 / summary</p>", in: folder)
        _ = try await fake.createNote(title: "B", body: "<p>nope</p>", in: folder)

        let match = try await fake.findNote(markerContaining: "11111111-1111-1111-1111-111111111111 / summary", in: folder)
        XCTAssertEqual(match?.title, "A")
    }

    func testUpdateNoteReplacesBody() async throws {
        let fake = InMemoryAppleNotesScripting()
        let folder = try await fake.ensureFolder(named: "Casablanca")
        let ref = try await fake.createNote(title: "T", body: "<p>old</p>", in: folder)

        try await fake.updateNote(id: ref.id, title: "T2", body: "<p>new</p>")

        let body = try await fake.noteBody(id: ref.id)
        XCTAssertEqual(body, "<p>new</p>")
    }
}
