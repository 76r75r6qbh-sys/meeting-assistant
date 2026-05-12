import Foundation
import AppKit

/// Production `NSAppleScript`-backed implementation. Modeled as an `actor` so its methods are
/// implicitly serialized — Notes scripting is not reentrant-safe.
///
/// Note: `NSAppleScript.executeAndReturnError` is fully synchronous and not cancellable. The
/// 30-second timeout resolves the awaiting `Task` but the underlying worker thread continues
/// until the script returns. The leaked thread is accepted as a v1 trade-off.
actor NSAppleScriptAppleNotesScripting: AppleNotesScripting {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func ensureFolder(named name: String) async throws -> AppleNotesFolderRef {
        let source = """
        tell application "Notes"
            try
                set targetAccount to default account
            on error
                set targetAccount to first account
            end try
            set folderName to "\(escape(name))"
            if not (exists folder folderName of targetAccount) then
                make new folder at targetAccount with properties {name:folderName}
            end if
            set f to folder folderName of targetAccount
            return (id of f) & "||" & (name of f)
        end tell
        """
        let raw = try await run(source)
        return try parseFolderRef(raw)
    }

    func findNote(markerContaining marker: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef? {
        let source = """
        tell application "Notes"
            set folderId to "\(escape(folder.id))"
            set markerText to "\(escape(marker))"
            try
                set theFolder to (first folder whose id is folderId)
            on error
                return ""
            end try
            repeat with n in (every note of theFolder)
                if (body of n) contains markerText then
                    return (id of n) & "||" & (name of n)
                end if
            end repeat
            return ""
        end tell
        """
        let raw = try await run(source)
        if raw.isEmpty { return nil }
        return try parseNoteRef(raw)
    }

    func noteBody(id: String) async throws -> String? {
        let source = """
        tell application "Notes"
            try
                return body of (first note whose id is "\(escape(id))")
            on error
                return "__CASABLANCA_NOT_FOUND__"
            end try
        end tell
        """
        let raw = try await run(source)
        return raw == "__CASABLANCA_NOT_FOUND__" ? nil : raw
    }

    func createNote(title: String, body: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef {
        let source = """
        tell application "Notes"
            set folderId to "\(escape(folder.id))"
            set theFolder to (first folder whose id is folderId)
            set newNote to make new note at theFolder with properties {name:"\(escape(title))", body:"\(escape(body))"}
            return (id of newNote) & "||" & (name of newNote)
        end tell
        """
        let raw = try await run(source)
        return try parseNoteRef(raw)
    }

    func updateNote(id: String, title: String, body: String) async throws {
        let source = """
        tell application "Notes"
            set theNote to (first note whose id is "\(escape(id))")
            set name of theNote to "\(escape(title))"
            set body of theNote to "\(escape(body))"
        end tell
        """
        _ = try await run(source)
    }

    // MARK: - Private

    private func parseFolderRef(_ raw: String) throws -> AppleNotesFolderRef {
        let parts = raw.components(separatedBy: "||")
        guard parts.count == 2 else { throw AppleNotesExportError.unexpectedResponse(raw) }
        return AppleNotesFolderRef(id: parts[0], name: parts[1])
    }

    private func parseNoteRef(_ raw: String) throws -> AppleNotesNoteRef {
        let parts = raw.components(separatedBy: "||")
        guard parts.count == 2 else { throw AppleNotesExportError.unexpectedResponse(raw) }
        return AppleNotesNoteRef(id: parts[0], title: parts[1])
    }

    private func run(_ source: String) async throws -> String {
        let timeoutSeconds = timeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let state = ResumeState()

            // Run NSAppleScript on a detached thread; it's synchronous and uncancellable.
            Thread.detachNewThread {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    state.resumeOnce {
                        continuation.resume(throwing: AppleNotesExportError.unexpectedResponse("could not compile script"))
                    }
                    return
                }
                let descriptor = script.executeAndReturnError(&errorInfo)
                if let errorInfo = errorInfo {
                    let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? ""
                    state.resumeOnce {
                        continuation.resume(throwing: AppleNotesExportError.from(appleScriptErrorCode: code, message: message))
                    }
                    return
                }
                let result = descriptor.stringValue ?? ""
                state.resumeOnce {
                    continuation.resume(returning: result)
                }
            }

            // Timeout watchdog on a separate dispatch queue so the script thread can't starve it.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                state.resumeOnce {
                    continuation.resume(throwing: AppleNotesExportError.timedOut)
                }
            }
        }
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

/// Single-resume guard for the timeout race between the script thread and the watchdog.
/// Resolves `CheckedContinuation`'s "must resume exactly once" requirement when two callbacks
/// can race to resume.
private final class ResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ work: () -> Void) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume { work() }
    }
}
