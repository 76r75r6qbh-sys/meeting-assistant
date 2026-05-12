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
    /// Look up a note by its exact title within the given folder. Used as a defensive
    /// fallback in case Apple Notes mangles or strips the body-embedded marker on save.
    /// Returns `nil` when no note in the folder has a name equal to `name`.
    func findNote(named name: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef?
    func noteBody(id: String) async throws -> String?
    func createNote(title: String, body: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef
    func updateNote(id: String, title: String, body: String) async throws
}
