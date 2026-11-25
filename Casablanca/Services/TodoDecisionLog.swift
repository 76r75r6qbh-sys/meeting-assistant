// Casablanca/Services/TodoDecisionLog.swift
import Foundation

/// One review decision on a proposed to-do, as written to the decision log.
struct TodoDecisionEntry: Codable, Equatable {
    enum Action: String, Codable {
        case accept, reject, edit
        case autoAccept = "auto_accept"
    }

    /// The to-do as it was after the decision.
    struct Item: Codable, Equatable {
        var task: String
        var owner: String?
        /// `yyyy-MM-dd`.
        var due: String?
        var timestamp: String?
        var quote: String?
    }

    struct Change: Codable, Equatable {
        var from: String?
        var to: String?
    }

    var date: Date
    var meetingID: UUID?
    var todoID: UUID
    var action: Action
    var item: Item
    /// Keys `"task"`, `"owner"`, `"due"`; only the fields that changed.
    var edit: [String: Change]?
    var verification: String?
    var verificationReason: String?
}

/// Append-only JSON Lines log of to-do review decisions (accept, reject,
/// edit, auto-accept), kept as feedback on extraction quality. Writing is
/// best effort: a failure is logged and never reaches the caller.
final class TodoDecisionLog: @unchecked Sendable {
    /// `~/Library/Application Support/Casablanca/feedback/todo-decisions.jsonl`.
    static let shared = TodoDecisionLog(
        fileURL: URL.applicationSupportDirectory
            .appending(path: "Casablanca", directoryHint: .isDirectory)
            .appending(path: "feedback", directoryHint: .isDirectory)
            .appending(path: "todo-decisions.jsonl", directoryHint: .notDirectory)
    )

    let fileURL: URL
    /// Serializes appends so two lines never interleave.
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Appends `entry` as one JSON line (sorted keys, ISO-8601 dates),
    /// creating the directory when needed.
    func append(_ entry: TodoDecisionEntry) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(entry)
            line.append(0x0A)

            let fileManager = FileManager.default
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .withoutOverwriting)
            }
        } catch {
            Log.persistence.error(
                "Writing the to-do decision log failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Removes every line of `meetingID` (the meeting was deleted, and its
    /// to-do text and quotes must go with it). Other lines, including ones
    /// this version cannot decode, are kept byte for byte and in order; the
    /// file is only rewritten (atomically) when a line was removed. Best
    /// effort: a failure is logged and never reaches the caller.
    func removeEntries(forMeetingID meetingID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let kept = lines.filter { line in
                (try? decoder.decode(MeetingReference.self, from: Data(line.utf8)))?.meetingID != meetingID
            }
            guard kept.count != lines.count else { return }
            let rewritten = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
            try Data(rewritten.utf8).write(to: fileURL, options: .atomic)
        } catch {
            Log.persistence.error(
                "Removing a meeting from the to-do decision log failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Deletes the whole log (Settings → To-do Review). A log that does not
    /// exist counts as deleted. Returns false (and logs) when removal failed.
    @discardableResult
    func deleteLog() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return true
        } catch {
            Log.persistence.error(
                "Deleting the to-do decision log failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Only the field removal needs, so a line from a newer entry shape still
    /// decodes.
    private struct MeetingReference: Decodable {
        var meetingID: UUID?
    }
}
