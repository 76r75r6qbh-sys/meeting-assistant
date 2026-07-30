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

    func testUnknownEnumValuesPreserveRawString() throws {
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
        // Unknown values are preserved (not coerced to a known fallback).
        XCTAssertEqual(item.kind, .unknown("mystery"))
        XCTAssertEqual(item.draftType, .unknown("carrier-pigeon"))
        XCTAssertEqual(item.priority, .unknown("urgent"))
        XCTAssertEqual(item.status, .unknown("in_limbo"))
        XCTAssertEqual(item.kind.rawValue, "mystery")
        XCTAssertEqual(item.status.rawValue, "in_limbo")
        XCTAssertTrue(doc.hadLenientFallback)
    }

    // MARK: - Data-preserving round-trip (Phase 2d)

    func testUnknownEnumStatusRoundTripsThroughSave() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-1", "status": "some_new_value", "body": "keep me" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        // A no-op-ish mutation triggers a full rewrite of the document.
        try ActionQueueStore.updateBody("keep me", for: "AQ-1", userDefaults: defaults)

        let raw = try firstRawItem()
        XCTAssertEqual(raw["status"] as? String, "some_new_value")

        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].status, .unknown("some_new_value"))
    }

    func testMalformedItemIsExcludedButRetainedAndReEmitted() throws {
        // Second item is structurally broken: `id` is an object, not a string.
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-good", "title": "Good item", "status": "pending" },
            { "id": { "nested": "broken" }, "title": "Broken item", "weird": [1, 2, 3] }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)

        // Good item visible to the UI; broken one excluded but retained.
        XCTAssertEqual(doc.items.count, 1)
        XCTAssertEqual(doc.items[0].id, "AQ-good")
        XCTAssertEqual(doc.unparsedItemCount, 1)
        XCTAssertTrue(doc.hadLenientFallback)

        // Save and confirm the broken item's original JSON is still present.
        try ActionQueueStore.approve(id: "AQ-good", userDefaults: defaults)
        let obj = try rawJSON()
        let items = obj["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 2)
        let broken = items.first { $0["title"] as? String == "Broken item" }
        XCTAssertNotNil(broken)
        XCTAssertNotNil(broken?["weird"])
        XCTAssertTrue(broken?["id"] is [String: Any])
    }

    func testApprovingGoodItemPreservesCoexistingBrokenItem() throws {
        // Core data-loss scenario: approving a good item must NOT delete the
        // broken item the agent wrote.
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-good", "title": "Good", "kind": "draft", "status": "pending", "body": "hi" },
            { "id": 12345, "title": "Numeric id is broken" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        try ActionQueueStore.approve(id: "AQ-good", editedBody: "edited", userDefaults: defaults)

        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items.count, 1)
        XCTAssertEqual(doc.items[0].status, .approved)
        XCTAssertEqual(doc.items[0].body, "edited")
        XCTAssertEqual(doc.unparsedItemCount, 1)

        let obj = try rawJSON()
        let items = obj["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 2)
        let broken = items.first { $0["title"] as? String == "Numeric id is broken" }
        XCTAssertNotNil(broken)
        XCTAssertEqual((broken?["id"] as? NSNumber)?.intValue, 12345)
    }

    func testUnknownItemKeysArePreservedOnRewrite() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-1", "title": "Item", "status": "pending", "futureField": "keep me", "nested": { "a": 1 } }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        try ActionQueueStore.approve(id: "AQ-1", userDefaults: defaults)

        let raw = try firstRawItem()
        XCTAssertEqual(raw["futureField"] as? String, "keep me")
        XCTAssertEqual((raw["nested"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(raw["status"] as? String, "approved")
    }

    func testUnknownTopLevelKeysArePreservedOnRewrite() throws {
        try write("""
        {
          "version": 1,
          "metadata": { "agent": "claude", "run": 42 },
          "items": [
            { "id": "AQ-1", "title": "Item", "status": "pending" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        try ActionQueueStore.approve(id: "AQ-1", userDefaults: defaults)

        let obj = try rawJSON()
        let metadata = obj["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["agent"] as? String, "claude")
        XCTAssertEqual((metadata?["run"] as? NSNumber)?.intValue, 42)
    }

    // MARK: - Large-integer precision in JSON passthrough

    /// Reads the on-disk file as a raw UTF-8 string (NOT via JSONSerialization,
    /// which would itself coerce large integers to Double and mask the bug).
    private func rawFileString() throws -> String {
        let data = try Data(contentsOf: queueURL)
        return String(data: data, encoding: .utf8)!
    }

    func testLargeIntegerInUnknownTopLevelKeySurvivesRoundTrip() throws {
        // `bigId` is larger than Int64.max — the old Int-then-Double decode
        // would corrupt it to `1e+19` (or `10000000000000000000`).
        try write("""
        {
          "version": 1,
          "bigId": 9999999999999999999,
          "items": [
            { "id": "AQ-1", "title": "Item", "status": "pending" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        try ActionQueueStore.approve(id: "AQ-1", userDefaults: defaults)

        // Assert against the raw on-disk bytes: the exact digits must be present
        // and no scientific-notation/magnitude corruption may appear.
        let onDisk = try rawFileString()
        XCTAssertTrue(onDisk.contains("9999999999999999999"),
                      "Large integer lost its exact digits on round trip: \(onDisk)")
        XCTAssertFalse(onDisk.contains("1e+19"), "Large integer corrupted to scientific notation")
        XCTAssertFalse(onDisk.contains("1E+19"), "Large integer corrupted to scientific notation")
    }

    func testBigIntegerInsideUnparsedItemSurvivesRoundTrip() throws {
        // Second item is structurally broken (numeric `id`) so it lands in
        // `unparsedItems` and is preserved verbatim. The 23-digit `ref` inside it
        // must keep its exact digits through the whole-document rewrite.
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-good", "title": "Good", "status": "pending", "body": "hi" },
            { "id": 12345, "title": "Broken item", "ref": 99999999999999999999999 }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.unparsedItemCount, 1)

        try ActionQueueStore.approve(id: "AQ-good", userDefaults: defaults)

        let onDisk = try rawFileString()
        XCTAssertTrue(onDisk.contains("99999999999999999999999"),
                      "23-digit integer lost its exact digits on round trip: \(onDisk)")
        XCTAssertFalse(onDisk.contains("e+"), "Big integer corrupted to scientific notation")
        XCTAssertFalse(onDisk.contains("E+"), "Big integer corrupted to scientific notation")
    }

    func testSmallNumbersAndFractionsRoundTripIntact() throws {
        // Existing small-number behaviour must be unaffected: small ints stay
        // exact, fractions keep their value. (A whole-number `42.0` may normalize
        // to `42` — acceptable, since JSON has no int/float distinction.)
        try write("""
        {
          "version": 1,
          "metadata": { "run": 42, "ratio": 3.14159, "neg": -17 },
          "items": [
            { "id": "AQ-1", "title": "Item", "status": "pending" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        try ActionQueueStore.approve(id: "AQ-1", userDefaults: defaults)

        let obj = try rawJSON()
        let metadata = obj["metadata"] as? [String: Any]
        XCTAssertEqual((metadata?["run"] as? NSNumber)?.intValue, 42)
        XCTAssertEqual((metadata?["neg"] as? NSNumber)?.intValue, -17)
        XCTAssertEqual((metadata?["ratio"] as? NSNumber)?.doubleValue ?? 0, 3.14159, accuracy: 1e-9)
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

    func testCompleteLocallySetsExecutionFields() throws {
        let defaults = try seedSingle(status: .pending, kind: .task)
        try ActionQueueStore.completeLocally(id: "AQ-1", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        let item = doc.items[0]
        XCTAssertEqual(item.status, .completed)
        XCTAssertNotNil(item.decidedAt)
        XCTAssertNotNil(item.executedAt)
        XCTAssertEqual(item.executionResult, "marked complete in Casablanca")

        // The fields must actually be on disk.
        let raw = try firstRawItem()
        XCTAssertEqual(raw["status"] as? String, "completed")
        XCTAssertEqual(raw["executionResult"] as? String, "marked complete in Casablanca")
        XCTAssertNotNil(raw["executedAt"] as? String)
    }

    func testCompleteDoesNotSetExecutionResult() throws {
        // The existing `complete(...)` path must NOT touch executionResult/executedAt.
        let defaults = try seedSingle(status: .followUp, kind: .task)
        try ActionQueueStore.complete(id: "AQ-1", userDefaults: defaults)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        let item = doc.items[0]
        XCTAssertEqual(item.status, .completed)
        XCTAssertNil(item.executionResult)
        XCTAssertNil(item.executedAt)

        let raw = try firstRawItem()
        XCTAssertNil(raw["executionResult"])
        XCTAssertNil(raw["executedAt"])
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

    // MARK: - Bucket schema (Task 1)

    func testBucketAndNewFieldsDecodeAndRoundTrip() throws {
        try write("""
        {
          "version": 1,
          "items": [
            {
              "id": "AQ-bucket",
              "title": "Ticket draft item",
              "status": "pending",
              "bucket": "ticket_draft",
              "attachments": ["/a/b.yaml"],
              "externalRef": "forta:x",
              "linkedItemIds": ["AQ-1", "AQ-2"]
            }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        var doc = try ActionQueueStore.load(userDefaults: defaults)
        var item = doc.items[0]
        XCTAssertEqual(item.bucket, .ticketDraft)
        XCTAssertEqual(item.attachments, ["/a/b.yaml"])
        XCTAssertEqual(item.externalRef, "forta:x")
        XCTAssertEqual(item.linkedItemIds, ["AQ-1", "AQ-2"])

        // A full rewrite must preserve all four fields on disk.
        try ActionQueueStore.approve(id: "AQ-bucket", userDefaults: defaults)
        let raw = try firstRawItem()
        XCTAssertEqual(raw["bucket"] as? String, "ticket_draft")
        XCTAssertEqual(raw["attachments"] as? [String], ["/a/b.yaml"])
        XCTAssertEqual(raw["externalRef"] as? String, "forta:x")
        XCTAssertEqual(raw["linkedItemIds"] as? [String], ["AQ-1", "AQ-2"])

        doc = try ActionQueueStore.load(userDefaults: defaults)
        item = doc.items[0]
        XCTAssertEqual(item.bucket, .ticketDraft)
        XCTAssertEqual(item.attachments, ["/a/b.yaml"])
        XCTAssertEqual(item.externalRef, "forta:x")
        XCTAssertEqual(item.linkedItemIds, ["AQ-1", "AQ-2"])
    }

    func testUnknownBucketPreservedRawAndRoundTrips() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-1", "title": "Item", "status": "pending", "bucket": "totally_new" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        var doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].bucket, .unknown("totally_new"))
        XCTAssertEqual(doc.items[0].bucket?.rawValue, "totally_new")
        XCTAssertTrue(doc.hadLenientFallback)

        try ActionQueueStore.approve(id: "AQ-1", userDefaults: defaults)
        let raw = try firstRawItem()
        XCTAssertEqual(raw["bucket"] as? String, "totally_new")

        doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].bucket, .unknown("totally_new"))
    }

    func testCalendarAndTopdeskDraftTypesDecodeAsKnownAndRoundTrip() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-cal", "title": "Cal", "status": "pending", "draftType": "calendar" },
            { "id": "AQ-td", "title": "TD", "status": "pending", "draftType": "topdesk" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        var doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].draftType, .calendar)
        XCTAssertEqual(doc.items[1].draftType, .topdesk)
        // Known cases must NOT trip the lenient fallback warning.
        XCTAssertFalse(doc.items[0].hasUnknownEnumValue)
        XCTAssertFalse(doc.items[1].hasUnknownEnumValue)

        try ActionQueueStore.approve(id: "AQ-cal", userDefaults: defaults)
        try ActionQueueStore.approve(id: "AQ-td", userDefaults: defaults)
        let obj = try rawJSON()
        let items = obj["items"] as! [[String: Any]]
        XCTAssertEqual(items[0]["draftType"] as? String, "calendar")
        XCTAssertEqual(items[1]["draftType"] as? String, "topdesk")

        doc = try ActionQueueStore.load(userDefaults: defaults)
        XCTAssertEqual(doc.items[0].draftType, .calendar)
        XCTAssertEqual(doc.items[1].draftType, .topdesk)
    }

    func testMissingBucketAndNewFieldsAreNil() throws {
        try write("""
        {
          "version": 1,
          "items": [
            { "id": "AQ-min", "title": "Bare item", "status": "pending" }
          ]
        }
        """)
        let defaults = makeDefaults(path: queueURL.path)
        let doc = try ActionQueueStore.load(userDefaults: defaults)
        let item = doc.items[0]
        XCTAssertNil(item.bucket)
        XCTAssertNil(item.attachments)
        XCTAssertNil(item.externalRef)
        XCTAssertNil(item.linkedItemIds)
        XCTAssertFalse(item.hasUnknownEnumValue)
    }

    func testBucketSortOrderMatchesAllCasesAndIsGapFree() {
        // `allCases` declaration order is the fixed display order; `sortOrder`
        // must agree with it and be a gap-free 0..<n so the grouping UI has a
        // single source of truth.
        let order = ActionBucket.allCases
        XCTAssertEqual(order.map(\.sortOrder), Array(0..<order.count))
        for bucket in order {
            XCTAssertFalse(bucket.displayName.isEmpty)
        }
        XCTAssertEqual(ActionBucket.unknown("x").sortOrder, order.count)
    }
}
