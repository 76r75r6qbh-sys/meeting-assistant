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

    /// Synchronous execution seam, invoked on the detached worker thread. Defaults to the real
    /// `NSAppleScript` path; tests inject a slow/blocking closure to exercise the timeout and
    /// single-flight guard deterministically without driving Notes.app.
    private let executeScript: (String) -> Result<String, AppleNotesExportError>

    /// Single-flight guard. Set `true` on the actor just before the worker thread is spawned and
    /// cleared ONLY by the worker thread's completion (hopping back onto the actor via
    /// `markScriptFinished`). The timeout watchdog deliberately does NOT touch this flag: when a
    /// script times out, its detached thread is still running `executeAndReturnError` and still
    /// driving Notes.app, so the flag must stay raised until that leaked script genuinely returns.
    /// A new `run(_:)` that arrives while the flag is raised fails fast with `.busy` instead of
    /// spawning a second concurrent script (Notes scripting is not reentrant-safe).
    private var scriptInFlight = false

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
        self.executeScript = NSAppleScriptAppleNotesScripting.executeWithNSAppleScript
    }

    /// Testing initializer that injects a custom synchronous execution seam.
    init(timeout: TimeInterval, executeScript: @escaping (String) -> Result<String, AppleNotesExportError>) {
        self.timeout = timeout
        self.executeScript = executeScript
    }

    /// Real production execution path: compile and run the script via `NSAppleScript`.
    /// Synchronous and uncancellable; runs on the detached worker thread.
    private static func executeWithNSAppleScript(_ source: String) -> Result<String, AppleNotesExportError> {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(.unexpectedResponse("could not compile script"))
        }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? ""
            return .failure(.from(appleScriptErrorCode: code, message: message))
        }
        return .success(descriptor.stringValue ?? "")
    }

    /// Clears the single-flight flag. Called from the worker thread's completion path by hopping
    /// back onto the actor, so the flag is always mutated under actor isolation. Owned solely by
    /// the worker completion — the timeout path never calls this.
    private func markScriptFinished() {
        scriptInFlight = false
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

    func findNote(named name: String, in folder: AppleNotesFolderRef) async throws -> AppleNotesNoteRef? {
        let source = """
        tell application "Notes"
            set folderId to "\(escape(folder.id))"
            set targetName to "\(escape(name))"
            try
                set theFolder to (first folder whose id is folderId)
            on error
                return ""
            end try
            try
                set matched to first note of theFolder whose name is targetName
                return (id of matched) & "||" & (name of matched)
            on error
                return ""
            end try
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
        // Single-flight guard: a previous script may have timed out (resuming its caller) while its
        // detached worker thread is still executing and driving Notes.app. Refuse to spawn a second
        // concurrent script — Notes scripting is not reentrant-safe.
        guard !scriptInFlight else {
            Log.export.error("Apple Notes script rejected: a previous script is still in flight (likely leaked after timeout)")
            throw AppleNotesExportError.busy
        }
        scriptInFlight = true

        let timeoutSeconds = timeout
        let execute = executeScript
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let state = ResumeState()

            // Run the script on a detached thread; it's synchronous and uncancellable.
            Thread.detachNewThread {
                let outcome = execute(source)
                // Clear the in-flight flag ONLY here, from the worker completion. Even if the
                // timeout already resumed the caller, the flag stays raised until this point —
                // the moment the (possibly leaked) script genuinely returns. Hop back onto the
                // actor so the flag is mutated under isolation.
                Task { await self.markScriptFinished() }
                switch outcome {
                case .success(let result):
                    state.resumeOnce {
                        continuation.resume(returning: result)
                    }
                case .failure(let error):
                    state.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout watchdog on a separate dispatch queue so the script thread can't starve it.
            // It only resumes the continuation; it deliberately does NOT touch `scriptInFlight`.
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
