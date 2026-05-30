// Casablanca/Services/Updates/UpdateInstaller.swift
import Foundation
import OSLog
import Darwin
import AppKit

protocol UpdateInstaller {
    @MainActor
    func install(stagedBundle: URL, currentBundle: URL, paths: UpdatePaths, now: Date) throws
}

final class DefaultUpdateInstaller: UpdateInstaller {
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    @MainActor
    func install(stagedBundle: URL, currentBundle: URL, paths: UpdatePaths, now: Date) throws {
        // Step 1: atomic swap (Task 11 fills this in).
        try atomicSwap(stagedBundle: stagedBundle, currentBundle: currentBundle)

        // Step 2: write relaunch script.
        try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
        let logPath = paths.installLog(at: now)
        let scriptPath = paths.relaunchScript(at: now)
        let body = Self.relaunchScript(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            newAppPath: currentBundle,
            logPath: logPath
        )
        try body.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Step 3: spawn helper detached.
        try spawnDetached(scriptPath: scriptPath)
    }

    @MainActor
    func atomicSwap(stagedBundle: URL, currentBundle: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: currentBundle.path) {
                _ = try fm.replaceItemAt(currentBundle, withItemAt: stagedBundle)
            } else {
                try fm.createDirectory(
                    at: currentBundle.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: stagedBundle, to: currentBundle)
            }
        } catch {
            throw UpdateError.swapFailed(error.localizedDescription)
        }
    }

    func spawnDetached(scriptPath: URL) throws {
        var fileActions: posix_spawn_file_actions_t? = nil
        var attrs: posix_spawnattr_t? = nil

        defer {
            if fileActions != nil { posix_spawn_file_actions_destroy(&fileActions) }
            if attrs != nil { posix_spawnattr_destroy(&attrs) }
        }

        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attrs) == 0 else {
            throw UpdateError.helperSpawnFailed("posix_spawn_*_init failed")
        }

        // Redirect stdin/stdout/stderr to /dev/null
        for fd in 0...2 {
            let rc = "/dev/null".withCString { devnull in
                posix_spawn_file_actions_addopen(&fileActions, Int32(fd), devnull, fd == 0 ? O_RDONLY : O_WRONLY, 0)
            }
            guard rc == 0 else {
                throw UpdateError.helperSpawnFailed("addopen for fd \(fd) failed: \(rc)")
            }
        }

        // Become a session leader (decouple from parent's process group)
        let flags = Int16(POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attrs, flags) == 0 else {
            throw UpdateError.helperSpawnFailed("posix_spawnattr_setflags failed")
        }

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"),
            strdup(scriptPath.path),
            nil
        ]
        defer { for ptr in argv where ptr != nil { free(ptr) } }

        let envp: [UnsafeMutablePointer<CChar>?] = [nil]

        let rc = posix_spawn(&pid, "/bin/sh", &fileActions, &attrs, argv, envp)
        if rc != 0 {
            throw UpdateError.helperSpawnFailed("posix_spawn returned \(rc)")
        }
    }

    static func relaunchScript(parentPID: Int32, newAppPath: URL, logPath: URL) -> String {
        let app = posixSingleQuote(newAppPath.path)
        let log = posixSingleQuote(logPath.path)
        // Wait on the parent PID itself, not a sentinel file. The previous
        // sentinel approach depended on `applicationWillTerminate` firing to
        // remove the file — which does not happen reliably when the app is
        // asked to quit while the update sheet is presented, so the helper would
        // time out and the new version would never launch. `kill -0` polling is
        // robust regardless of how the parent exits.
        return """
        #!/bin/sh
        set -u
        PARENT=\(parentPID)
        NEW_APP=\(app)
        LOG=\(log)

        log() { printf '%s %s\\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

        log "waiting for parent $PARENT to exit"
        i=0
        while kill -0 "$PARENT" 2>/dev/null; do
          sleep 0.2
          i=$((i+1))
          if [ "$i" -gt 150 ]; then
            log "parent $PARENT still alive after 30s, launching anyway"
            break
          fi
        done

        log "launching $NEW_APP"
        open -n "$NEW_APP"
        """
    }

    static func posixSingleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
