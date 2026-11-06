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

    func testSharedLogLivesInApplicationSupportFeedback() {
        XCTAssertTrue(TodoDecisionLog.shared.fileURL.path.hasSuffix("/Casablanca/feedback/todo-decisions.jsonl"))
        XCTAssertTrue(TodoDecisionLog.shared.fileURL.path.contains("/Library/Application Support/"))
    }
}
