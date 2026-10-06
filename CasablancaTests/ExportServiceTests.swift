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
