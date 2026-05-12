import Foundation

struct AppleNotesFolderRef: Equatable, Sendable {
    let id: String
    let name: String
}

struct AppleNotesNoteRef: Equatable, Sendable {
    let id: String
    let title: String
}

protocol AppleNotesScripting: Sendable {
    func ensureFolder(named name: String) async throws -> AppleNotesFolderRef
    func findNote(markerContaining marker: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef?
    func noteBody(id: String) async throws -> String?
    func createNote(title: String, body: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef
    func updateNote(id: String, title: String, body: String) async throws
}
