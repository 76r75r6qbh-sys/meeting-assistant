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
            sentinelPath: paths.sentinel,
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
        fatalError("implemented in Task 12")
    }

    static func relaunchScript(sentinelPath: URL, newAppPath: URL, logPath: URL) -> String {
        let sentinel = posixSingleQuote(sentinelPath.path)
        let app = posixSingleQuote(newAppPath.path)
        let log = posixSingleQuote(logPath.path)
        return """
        #!/bin/sh
        set -u
        SENTINEL=\(sentinel)
        NEW_APP=\(app)
        LOG=\(log)

        log() { printf '%s %s\\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

        log "waiting for parent to exit (sentinel: $SENTINEL)"
        i=0
        while [ -e "$SENTINEL" ]; do
          sleep 0.2
          i=$((i+1))
          if [ "$i" -gt 150 ]; then
            log "parent did not remove sentinel within 30s, launching anyway"
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
