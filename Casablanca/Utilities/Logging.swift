import Foundation
import OSLog

/// Centralized loggers, one per functional area, all under the app subsystem.
/// Mirrors the pattern already used by the Updates subsystem
/// (`UpdateService`'s `Logger(subsystem: "nl.medicore.casablanca", category: "update")`).
enum Log {
    private static let subsystem = "nl.medicore.casablanca"

    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let summarization = Logger(subsystem: subsystem, category: "summarization")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let actionQueue = Logger(subsystem: subsystem, category: "actionQueue")
    static let search = Logger(subsystem: subsystem, category: "search")
}

/// Runs `body`, logging any thrown error at `.warning` instead of propagating it.
/// Use for best-effort cleanup (removing temp files, closing file handles,
/// deleting stale sessions) where a failure must not abort the surrounding
/// operation but should still leave a trace in the log.
func bestEffort(_ label: StaticString, _ log: Logger, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        log.warning("\(String(describing: label), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }
}
