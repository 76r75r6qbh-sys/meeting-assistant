import Foundation
import OSLog

@MainActor
struct UpdateLaunchHousekeeping {
    let paths: UpdatePaths
    private static let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    /// Spec Phase 9, in order: wipe staging, delete orphan relaunch scripts, unconditionally rewrite the sentinel.
    func runOnLaunch() {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.stagingRoot.path) {
            try? fm.removeItem(at: paths.stagingRoot)
        }
        if let entries = try? fm.contentsOfDirectory(at: paths.updatesRoot, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent.hasPrefix("relaunch-") && url.pathExtension == "sh" {
                try? fm.removeItem(at: url)
            }
        }
        try? fm.createDirectory(at: paths.updatesRoot, withIntermediateDirectories: true)
        try? Data().write(to: paths.sentinel)
        Self.logger.info("launch housekeeping done; sentinel at \(paths.sentinel.path)")
    }

    func removeSentinelOnTerminate() {
        try? FileManager.default.removeItem(at: paths.sentinel)
    }
}
