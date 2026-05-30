import Foundation
import XCTest
@testable import Casablanca

final class ActionQueueStoreTests: XCTestCase {
    // MARK: - Helpers

    /// A temp directory unique to each test, cleaned up in tearDown.
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActionQueueStoreTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeDefaults(path: String?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ActionQueueStoreTests.\(UUID().uuidString)")!
        if let path {
            defaults.set(path, forKey: AppPreferenceKey.actionQueuePath)
        }
        return defaults
    }

    private var queueURL: URL { tempDir.appendingPathComponent("action-queue.json") }

    private func write(_ json: String) throws {
        try json.write(to: queueURL, atomically: true, encoding: .utf8)
    }

    private func rawJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: queueURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func firstRawItem() throws -> [String: Any] {
        let obj = try rawJSON()
        let items = obj["items"] as! [[String: Any]]
        return items[0]
    }

    // MARK: - Round-trip decode

    func testRoundTripDecodeOfRealisticFile() throws {
        try write("""
        {
          "version": 1,
          "updatedAt": "2026-05-30T09:00:00Z",
          "items": [
            {
              "id": "AQ-20260529-01",
              "kind": "draft",
              "draftType": "email",
              "title": "Reply to Luuk Geijsen",
              "priority": "medium",
              "target": "email: l.geijsen@praktikon.nl",
              "source": "Luuk Geijsen 2026-05-29",
              "rationale": "BergOp koppeling.",
              "body": "Hi Luuk,\\n\\nThanks.",
              "proposedAction": "Send this reply.",
              "status": "pending",
              "decisionNote": null,
              "createdAt": "2026-05-29T13:44:00Z",
              "decidedAt": null,
              "executedAt": null,
              "executionResult": null
            }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(doc.items.count, 1)
        let item = doc.items[0]
        XCTAssertEqual(item.id, "AQ-20260529-01")
        XCTAssertEqual(item.kind, .draft)
        XCTAssertEqual(item.draftType, .email)
        XCTAssertEqual(item.priority, .medium)
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.body, "Hi Luuk,\n\nThanks.")
        XCTAssertNotNil(item.createdAt)
        XCTAssertNil(item.decidedAt)
    }

    func testDecodesFractionalSecondsDates() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-1", "createdAt": "2026-05-29T13:44:00.123Z" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertNotNil(doc.items[0].createdAt)
    }

    func testDecodesFollowUpAndAwaitingContextRawValues() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-1", "status": "follow_up" },
            { "id": "AQ-2", "status": "awaiting_context" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .followUp)
        XCTAssertEqual(doc.items[1].status, .awaitingContext)
    }

    // MARK: - Lenient decode

    func testLenientDecodeWithMissingOptionalFields() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-minimal", "title": "Bare item" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        let item = doc.items[0]
        XCTAssertEqual(item.id, "AQ-minimal")
        XCTAssertEqual(item.kind, .task)       // fallback
        XCTAssertEqual(item.priority, .medium) // fallback
        XCTAssertEqual(item.status, .pending)  // fallback
        XCTAssertEqual(item.body, "")
        XCTAssertNil(item.draftType)
    }

    func testUnknownEnumValuesFallBack() throws {
        try write("""
        {
          "version": 1,
          "items": [
            {
              "id": "AQ-weird",
              "kind": "mystery",
              "draftType": "carrier-pigeon",
              "priority": "urgent",
              "status": "in_limbo"
            }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        let item = doc.items[0]
        XCTAssertEqual(item.kind, .task)
        XCTAssertEqual(item.draftType, .other)
        XCTAssertEqual(item.priority, .medium)
        XCTAssertEqual(item.status, .pending)
    }

    // MARK: - Absent file

    func testAbsentFileReturnsEmptyDoc() throws {
        let defaults = makeDefaults(path: queueURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.version, 1)
        XCTAssertTrue(doc.items.isEmpty)
    }

    // MARK: - Tilde expansion / default path

    func testEmptyPreferenceUsesDefaultPath() throws {
        let defaults = makeDefaults(path: "")
        let url = try XCTUnwrap(ActionQueueStore.fileURL(userDefaults: defaults))
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertTrue(url.path.hasSuffix("memory/action-queue.json"))
        XCTAssertTrue(url.path.contains(".claude"))
    }

    func testTildePathIsExpanded() throws {
        let defaults = makeDefaults(path: "~/some-folder/action-queue.json")
        let url = try XCTUnwrap(ActionQueueStore.fileURL(userDefaults: defaults))
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertTrue(url.path.hasSuffix("some-folder/action-queue.json"))
    }

    // MARK: - Mutations

    private func seedSingle(status: ActionItemStatus = .pending, kind: ActionItemKind = .draft) throws -> UserDefaults {
        try write("""
        {
          "version": 1,
          "items": [
            {
              "id": "AQ-1",
              "kind": "\(kind.rawValue)",
              "title": "Item one",
              "status": "\(status.rawValue)",
              "body": "original body",
              "createdAt": "2026-05-29T10:00:00Z"
            }
          ]
        }
        """)
        return makeDefaults(path: queueURL.path)
    }

    func testApproveSetsStatusAndDecidedAt() throws {
        let defaults = try seedSingle()
        try ActionQueueStore.approve(id: "AQ-1", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .approved)
        XCTAssertNotNil(doc.items[0].decidedAt)
        XCTAssertNotNil(doc.updatedAt)
    }

    func testApproveWithEditedBodyUpdatesBody() throws {
        let defaults = try seedSingle()
        try ActionQueueStore.approve(id: "AQ-1", editedBody: "edited body", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .approved)
        XCTAssertEqual(doc.items[0].body, "edited body")
    }

    func testDeclineSetsStatusAndNote() throws {
        let defaults = try seedSingle()
        try ActionQueueStore.decline(id: "AQ-1", note: "not now", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .declined)
        XCTAssertEqual(doc.items[0].decisionNote, "not now")
        XCTAssertNotNil(doc.items[0].decidedAt)
    }

    func testPostponeSetsDeferred() throws {
        let defaults = try seedSingle()
        try ActionQueueStore.postpone(id: "AQ-1", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .deferred)
        XCTAssertNotNil(doc.items[0].decidedAt)
    }

    func testCompleteSetsCompleted() throws {
        let defaults = try seedSingle(status: .followUp, kind: .task)
        try ActionQueueStore.complete(id: "AQ-1", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .completed)
        XCTAssertNotNil(doc.items[0].decidedAt)
    }

    func testRequestRevisionSetsStatusAndPrompt() throws {
        let defaults = try seedSingle()
        try ActionQueueStore.requestRevision(id: "AQ-1", prompt: "propose a call instead", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .revisionRequested)
        XCTAssertEqual(doc.items[0].revisionPrompt, "propose a call instead")
        XCTAssertNotNil(doc.items[0].decidedAt)
    }

    func testRevisionRequestedRawValueDecodes() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-1", "status": "revision_requested", "revisionPrompt": "make it shorter" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .revisionRequested)
        XCTAssertEqual(doc.items[0].revisionPrompt, "make it shorter")
    }

    func testReopenSetsPending() throws {
        let defaults = try seedSingle(status: .declined)
        try ActionQueueStore.reopen(id: "AQ-1", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .pending)
    }

    func testUpdateBodyDoesNotChangeStatus() throws {
        let defaults = try seedSingle()
        try ActionQueueStore.updateBody("just body", for: "AQ-1", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].body, "just body")
        XCTAssertEqual(doc.items[0].status, .pending)
    }

    func testMutationOfUnknownIdIsNoop() throws {
        let defaults = try seedSingle()
        try ActionQueueStore.approve(id: "does-not-exist", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .pending)
    }

    // MARK: - Atomic save round-trips full schema

    func testSaveRoundTripsFullKnownSchema() throws {
        try write("""
        {
          "version": 1,
          "updatedAt": "2026-05-30T09:00:00Z",
          "items": [
            {
              "id": "AQ-1",
              "kind": "draft",
              "draftType": "teams",
              "title": "Ping Kim",
              "priority": "high",
              "target": "teams: Kim",
              "source": "chat",
              "rationale": "status",
              "body": "Hi Kim",
              "proposedAction": "send",
              "status": "pending",
              "createdAt": "2026-05-29T13:44:00Z"
            }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        try ActionQueueStore.approve(id: "AQ-1", userDefaults: defaults)

        // Re-decode after save and confirm all known fields survived.
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        let item = doc.items[0]
        XCTAssertEqual(item.draftType, .teams)
        XCTAssertEqual(item.priority, .high)
        XCTAssertEqual(item.target, "teams: Kim")
        XCTAssertEqual(item.source, "chat")
        XCTAssertEqual(item.rationale, "status")
        XCTAssertEqual(item.proposedAction, "send")
        XCTAssertEqual(item.body, "Hi Kim")
        XCTAssertNotNil(item.createdAt)
        XCTAssertEqual(item.status, .approved)

        // Dates encoded without fractional seconds.
        let raw = try firstRawItem()
        let decidedAt = raw["decidedAt"] as? String
        XCTAssertNotNil(decidedAt)
        XCTAssertFalse(decidedAt!.contains("."))
    }
}
