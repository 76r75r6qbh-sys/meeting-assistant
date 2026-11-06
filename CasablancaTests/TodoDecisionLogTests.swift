// CasablancaTests/TodoDecisionLogTests.swift
import Foundation
import XCTest
@testable import Casablanca

final class TodoDecisionLogTests: XCTestCase {
    /// A fresh temporary directory, removed when the test ends. The log under
    /// test never points at Application Support.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodoDecisionLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entry(_ action: TodoDecisionEntry.Action, task: String, edit: [String: TodoDecisionEntry.Change]? = nil) -> TodoDecisionEntry {
        TodoDecisionEntry(
            date: Date(timeIntervalSince1970: 1_793_000_000),
            meetingID: UUID(),
            todoID: UUID(),
            action: action,
            item: .init(task: task, owner: "Youri", due: "2026-11-06", timestamp: "12:34", quote: "ik stuur\nde offerte"),
            edit: edit,
            verification: "supported",
            verificationReason: "Youri zegt het."
        )
    }

    func testAppendsOneJSONLinePerDecision() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("todo-decisions.jsonl")
        let log = TodoDecisionLog(fileURL: fileURL)
        let first = entry(.autoAccept, task: "Stuur offerte")
        let second = entry(.edit, task: "Plan demo", edit: ["task": .init(from: "Plan de demo", to: "Plan demo")])

        log.append(first)
        log.append(second)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "one line per decision, even with a newline in the quote")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(TodoDecisionEntry.self, from: Data(lines[0].utf8)), first)
        XCTAssertEqual(try decoder.decode(TodoDecisionEntry.self, from: Data(lines[1].utf8)), second)
        XCTAssertTrue(lines[0].contains(#""action":"auto_accept""#))
        XCTAssertTrue(lines[0].contains(#""date":"2026-"#), "ISO-8601 dates")
        XCTAssertLessThan(try XCTUnwrap(lines[0].range(of: #""action""#)).lowerBound,
                          try XCTUnwrap(lines[0].range(of: #""date""#)).lowerBound, "sorted keys")
    }

    func testCreatesMissingDirectory() throws {
        let fileURL = try makeTemporaryDirectory()
            .appendingPathComponent("feedback/nested", isDirectory: true)
            .appendingPathComponent("todo-decisions.jsonl")
        let log = TodoDecisionLog(fileURL: fileURL)

        log.append(entry(.accept, task: "Stuur offerte"))

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
    }

    func testUnwritableLocationDoesNotThrow() throws {
        // A regular file where the log's parent directory should be.
        let blocker = try makeTemporaryDirectory().appendingPathComponent("not-a-directory")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let fileURL = blocker.appendingPathComponent("todo-decisions.jsonl")
        let log = TodoDecisionLog(fileURL: fileURL)

        log.append(entry(.reject, task: "Plan demo"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "x")
    }

    // MARK: - Removal (privacy)

    private func entry(_ task: String, meetingID: UUID?) -> TodoDecisionEntry {
        var value = entry(.accept, task: task)
        value.meetingID = meetingID
        return value
    }

    func testRemoveEntriesForAMeetingKeepsOtherMeetingsLinesIntact() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("todo-decisions.jsonl")
        let log = TodoDecisionLog(fileURL: fileURL)
        let deleted = UUID()
        let kept = UUID()
        log.append(entry("Stuur offerte", meetingID: deleted))
        log.append(entry("Plan demo", meetingID: kept))
        log.append(entry("Bel Kim", meetingID: deleted))
        log.append(entry("Losse taak", meetingID: nil))
        let before = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
        // A line this version cannot decode is not ours to judge: kept.
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()

        log.removeEntries(forMeetingID: deleted)

        let after = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(after.hasSuffix("\n"))
        XCTAssertEqual(after.split(separator: "\n").map(String.init), [before[1], before[3], "not json"],
                       "other meetings' lines stay byte-for-byte, in order")
        XCTAssertFalse(after.contains(deleted.uuidString))

        log.append(entry("Nieuw", meetingID: kept))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").count, 4,
                       "appending still works after a removal")
    }

    func testRemoveEntriesWithoutAMatchLeavesTheFileUntouched() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("todo-decisions.jsonl")
        let log = TodoDecisionLog(fileURL: fileURL)
        log.append(entry("Plan demo", meetingID: UUID()))
        let before = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        log.removeEntries(forMeetingID: UUID())

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), text)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date, before)
    }

    func testRemoveEntriesNeverThrowsOnAMissingOrUnreadableLog() throws {
        let directory = try makeTemporaryDirectory()
        // Missing file.
        TodoDecisionLog(fileURL: directory.appendingPathComponent("missing.jsonl")).removeEntries(forMeetingID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing.jsonl").path))
        // A directory where the log file should be: unreadable as text.
        let blocker = directory.appendingPathComponent("todo-decisions.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        TodoDecisionLog(fileURL: blocker).removeEntries(forMeetingID: UUID())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDeleteLogRemovesTheFileAndToleratesAMissingOne() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("todo-decisions.jsonl")
        let log = TodoDecisionLog(fileURL: fileURL)
        log.append(entry("Plan demo", meetingID: UUID()))

        XCTAssertTrue(log.deleteLog())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(log.deleteLog(), "a log that is already gone counts as deleted")
    }

    func testSharedLogLivesInApplicationSupportFeedback() {
        XCTAssertTrue(TodoDecisionLog.shared.fileURL.path.hasSuffix("/Casablanca/feedback/todo-decisions.jsonl"))
        XCTAssertTrue(TodoDecisionLog.shared.fileURL.path.contains("/Library/Application Support/"))
    }
}
