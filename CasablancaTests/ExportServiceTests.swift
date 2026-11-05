import Foundation
import XCTest
@testable import Casablanca

/// Every case here writes real files, so the vault root is a per-test temporary
/// directory reached through a scratch preference domain. The standard domain is
/// off limits: the test host shares the app's bundle id, so writing there would
/// repoint the user's own Obsidian vault setting (and, before the exporter took
/// an injectable domain, export straight into the user's real vault).
@MainActor
final class ExportServiceTests: XCTestCase {
    /// Scratch vault + scratch preference domain, both torn down for us, with
    /// the resolved vault root proven to be outside the user's folders.
    private func makeGuardedDefaults() -> UserDefaults {
        let defaults = makeScratchDefaults(vaultRoot: makeScratchVault("export"), label: "export")
        defaults.set(ExportDestination.obsidian.rawValue, forKey: AppPreferenceKey.exportDestination)
        assertScratchVault(defaults)
        return defaults
    }

    func testExportRawNotesRendersFreeformSection() async throws {
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Freeform notes go here."

        let markdown = try await exportRawNotesMarkdown(for: meeting, defaults: makeGuardedDefaults())

        XCTAssertTrue(markdown.contains("## Freeform Notes"))
        XCTAssertTrue(markdown.contains("Freeform notes go here."))
    }

    func testExportRawNotesUsesPlaceholderWhenNoFreeformNotesExist() async throws {
        let meeting = Meeting(title: "Planning", date: .now)

        let markdown = try await exportRawNotesMarkdown(for: meeting, defaults: makeGuardedDefaults())

        XCTAssertTrue(markdown.contains("## Freeform Notes"))
        XCTAssertTrue(markdown.contains("_No freeform notes captured._"))
    }

    func testFrontmatterIncludesTagsWhenPresent() async throws {
        let meeting = Meeting(title: "Tagged Sync", date: .now)
        meeting.setTags(["wegiz", "orchestra"])

        let markdown = try await exportRawNotesMarkdown(for: meeting, defaults: makeGuardedDefaults())

        XCTAssertTrue(markdown.contains("tags:"), "Frontmatter must include a tags key when present")
        XCTAssertTrue(markdown.contains("- \"wegiz\""))
        XCTAssertTrue(markdown.contains("- \"orchestra\""))
    }

    func testYAMLEscapingHandlesBackslashQuoteAndNewlines() {
        XCTAssertEqual(ObsidianMeetingExporter.yamlEscaped(#"C:\temp "x""#), #""C:\\temp \"x\"""#)
        XCTAssertEqual(ObsidianMeetingExporter.yamlEscaped("a\nb\r\nc\td"), #""a\nb\nc\td""#)
        XCTAssertEqual(ObsidianMeetingExporter.yamlEscaped(#"end\"#), #""end\\""#)
    }

    func testFrontmatterStaysValidForTitleWithBackslashAndNewline() async throws {
        let meeting = Meeting(title: "Sync \\ review\nsecond line", date: .now)

        let markdown = try await exportRawNotesMarkdown(for: meeting, defaults: makeGuardedDefaults())

        XCTAssertTrue(markdown.contains(#"meeting_title: "Sync \\ review\nsecond line""#))
        let frontmatter = markdown.components(separatedBy: "---")[1]
        XCTAssertFalse(frontmatter.contains("\nsecond line"), "A raw newline would break the frontmatter")
    }

    func testFrontmatterOmitsTagsWhenEmpty() async throws {
        let meeting = Meeting(title: "Untagged Sync", date: .now)

        let markdown = try await exportRawNotesMarkdown(for: meeting, defaults: makeGuardedDefaults())

        XCTAssertFalse(markdown.contains("tags:"), "Frontmatter must omit the tags key when there are no tags")
    }

    func test_tagsFrontmatterLine_pureFormatting() {
        let withTags = Meeting(title: "X", date: .now)
        withTags.setTags(["Wegiz", "ai"])
        let line = ObsidianMeetingExporter.tagsFrontmatterLine(for: withTags)
        XCTAssertEqual(line, "\ntags:\n  - \"wegiz\"\n  - \"ai\"")

        let empty = Meeting(title: "Y", date: .now)
        XCTAssertEqual(ObsidianMeetingExporter.tagsFrontmatterLine(for: empty), "")
    }

    // MARK: - Action Items kept in the Notes file survive a re-export

    private static let actionItemsFixture = """
    # Raw Notes

    ## Freeform Notes

    old notes

    ## Action Items

    - [ ] Send roadmap <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->
    - [x] Book room <!-- casablanca-todo: 660E8400-E29B-41D4-A716-446655440000 -->
    """

    func testExportCompletedMeetingPreservesActionItemsInExistingNotesFile() throws {
        let defaults = makeGuardedDefaults()
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "new notes"
        meeting.summary = "A summary."
        let notesURL = try existingNotesURL(for: meeting, defaults: defaults, contents: Self.actionItemsFixture)

        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)

        let markdown = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("new notes"))
        XCTAssertFalse(markdown.contains("old notes"))
        XCTAssertTrue(markdown.contains("## Action Items"))
        XCTAssertTrue(markdown.contains("- [ ] Send roadmap <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->"))
        XCTAssertTrue(markdown.contains("- [x] Book room <!-- casablanca-todo: 660E8400-E29B-41D4-A716-446655440000 -->"))
    }

    func testExportRawNotesPreservesActionItemsInExistingNotesFile() throws {
        let defaults = makeGuardedDefaults()
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "new notes"
        let notesURL = try existingNotesURL(for: meeting, defaults: defaults, contents: Self.actionItemsFixture)

        _ = try ObsidianMeetingExporter.exportRawNotes(meeting, userDefaults: defaults)

        let markdown = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("new notes"))
        XCTAssertTrue(markdown.contains("- [ ] Send roadmap <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->"))
        XCTAssertTrue(markdown.contains("- [x] Book room <!-- casablanca-todo: 660E8400-E29B-41D4-A716-446655440000 -->"))
    }

    func testExportWithoutExistingActionItemsWritesSameOutputAsFreshExport() throws {
        let defaults = makeGuardedDefaults()
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "new notes"

        let fresh = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let freshMarkdown = try String(contentsOf: fresh.notesURL, encoding: .utf8)
        XCTAssertFalse(freshMarkdown.contains("## Action Items"))

        try "# Stale\n\n## Freeform Notes\n\nold notes".write(to: fresh.notesURL, atomically: true, encoding: .utf8)
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        XCTAssertEqual(try String(contentsOf: fresh.notesURL, encoding: .utf8), freshMarkdown)

        try "# Stale".write(to: fresh.notesURL, atomically: true, encoding: .utf8)
        _ = try ObsidianMeetingExporter.exportRawNotes(meeting, userDefaults: defaults)
        let rawMarkdown = try String(contentsOf: fresh.notesURL, encoding: .utf8)
        XCTAssertFalse(rawMarkdown.contains("## Action Items"))
        XCTAssertFalse(rawMarkdown.contains("# Stale"))
    }

    /// A Notes file that exists but cannot be read must fail the export, not be
    /// treated as absent and overwritten (which would wipe its Action Items).
    func testExportThrowsAndLeavesUnreadableNotesFileUntouched() throws {
        let defaults = makeGuardedDefaults()
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "new notes"
        let notesURL = try existingNotesURL(for: meeting, defaults: defaults, contents: "")
        let invalidUTF8 = Data([0x23, 0x20, 0xFF, 0xFE, 0xFD, 0x0A])
        try invalidUTF8.write(to: notesURL)

        XCTAssertThrowsError(try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults))
        XCTAssertEqual(try Data(contentsOf: notesURL), invalidUTF8)

        XCTAssertThrowsError(try ObsidianMeetingExporter.exportRawNotes(meeting, userDefaults: defaults))
        XCTAssertEqual(try Data(contentsOf: notesURL), invalidUTF8)
    }

    /// Seeds the meeting's Notes file in the scratch vault and returns its URL.
    private func existingNotesURL(for meeting: Meeting, defaults: UserDefaults, contents: String) throws -> URL {
        let directory = try XCTUnwrap(ObsidianMeetingFiles.meetingNotesDirectory(userDefaults: defaults))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(meeting.obsidianFileName) - Notes.md")
        TestVaultGuard.assertTemporary(url, "seeded notes file")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Export through `ExportService` (so the routing + injection path is
    /// exercised) and hand back the raw-notes markdown, asserting on the way
    /// that nothing landed outside the scratch vault.
    private func exportRawNotesMarkdown(
        for meeting: Meeting,
        defaults: UserDefaults,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String {
        let result = try await ExportService.exportRawNotes(meeting, defaults: defaults)
        guard case .obsidian(let export) = result else {
            XCTFail("Expected obsidian destination", file: file, line: line)
            return ""
        }
        TestVaultGuard.assertTemporary(export.notesURL, "exported notes file", file: file, line: line)
        return try String(contentsOf: export.notesURL, encoding: .utf8)
    }
}
