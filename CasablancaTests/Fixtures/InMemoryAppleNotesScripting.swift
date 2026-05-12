import Foundation
@testable import Casablanca

final actor InMemoryAppleNotesScripting: AppleNotesScripting {
    struct StoredNote {
        var id: String
        var title: String
        var body: String
        var folderId: String
    }

    private(set) var folders: [AppleNotesFolderRef] = []
    private(set) var notes: [StoredNote] = []
    private(set) var calls: [String] = []
    var ensureFolderError: Error?
    var createNoteError: Error?
    var updateNoteError: Error?
    var findNoteError: Error?
    var noteBodyError: Error?

    func setEnsureFolderError(_ error: Error?) { ensureFolderError = error }
    func setCreateNoteError(_ error: Error?) { createNoteError = error }
    func setUpdateNoteError(_ error: Error?) { updateNoteError = error }
    func setFindNoteError(_ error: Error?) { findNoteError = error }
    func setNoteBodyError(_ error: Error?) { noteBodyError = error }

    /// Simulate an out-of-band rewrite (e.g. user deletes/renames the folder in Notes).
    func removeFolder(named name: String) {
        if let folder = folders.first(where: { $0.name == name }) {
            folders.removeAll { $0.id == folder.id }
            notes.removeAll { $0.folderId == folder.id }
        }
    }

    func ensureFolder(named name: String) async throws -> AppleNotesFolderRef {
        calls.append("ensureFolder:\(name)")
        if let error = ensureFolderError { throw error }
        if let existing = folders.first(where: { $0.name == name }) { return existing }
        let folder = AppleNotesFolderRef(id: "folder-\(folders.count + 1)", name: name)
        folders.append(folder)
        return folder
    }

    func findNote(markerContaining marker: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef? {
        calls.append("findNote:\(marker):\(folder.id)")
        if let error = findNoteError { throw error }
        if let note = notes.first(where: { $0.folderId == folder.id && $0.body.contains(marker) }) {
            return AppleNotesNoteRef(id: note.id, title: note.title)
        }
        return nil
    }

    func noteBody(id: String) async throws -> String? {
        calls.append("noteBody:\(id)")
        if let error = noteBodyError { throw error }
        return notes.first(where: { $0.id == id })?.body
    }

    func createNote(title: String, body: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef {
        calls.append("createNote:\(title):\(folder.id)")
        if let error = createNoteError { throw error }
        let note = StoredNote(id: "note-\(notes.count + 1)", title: title, body: body, folderId: folder.id)
        notes.append(note)
        return AppleNotesNoteRef(id: note.id, title: note.title)
    }

    func updateNote(id: String, title: String, body: String) async throws {
        calls.append("updateNote:\(id)")
        if let error = updateNoteError { throw error }
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "InMemoryAppleNotesScripting", code: 404, userInfo: [NSLocalizedDescriptionKey: "Note not found"])
        }
        notes[index].title = title
        notes[index].body = body
    }
}
