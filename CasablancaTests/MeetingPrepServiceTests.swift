import Foundation
import XCTest
@testable import Casablanca

/// Prep notes are written into the vault, so every case here resolves its vault
/// root from a scratch preference domain pointed at a temporary directory —
/// never the standard domain, which in this test host is the user's own.
final class MeetingPrepServiceTests: XCTestCase {
    func testPrepURLUsesMeetingNotesFolderAndPrepSuffix() {
        let defaults = makeScratchDefaults(label: "prep-path")
        defaults.set("/tmp/obsidian-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        let prepURL = MeetingPrepService.prepURL(for: meeting, userDefaults: defaults)

        XCTAssertEqual(
            prepURL?.path,
            "/tmp/obsidian-vault/meeting notes/2025-04-12 Weekly Sync - Prep.md"
        )
    }

    func testLoadPrepMarkdownReturnsContentsWhenPrepFileExists() throws {
        let defaults = makeScratchDefaults(label: "prep-exists")
        let vaultURL = makeScratchVault("prep")
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try "# Agenda\n\n- Review roadmap".write(to: prepURL, atomically: true, encoding: .utf8)

        let markdown = MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults)

        XCTAssertEqual(markdown, "# Agenda\n\n- Review roadmap")
    }

    func testLoadPrepMarkdownReturnsNilWhenVaultPathMissing() {
        let defaults = makeScratchDefaults(label: "prep-missing-vault")
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        XCTAssertNil(MeetingPrepService.prepURL(for: meeting, userDefaults: defaults))
        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    func testLoadPrepMarkdownReturnsNilWhenPrepFileMissing() {
        let defaults = makeScratchDefaults(label: "prep-missing-file")
        defaults.set("/tmp/obsidian-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    func testLoadPrepMarkdownMatchesTrimmedPrepFilenameWhenMeetingTitleHasTrailingWhitespace() throws {
        let defaults = makeScratchDefaults(label: "prep-trailing-space")
        let vaultURL = makeScratchVault("prep")
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)

        let meeting = Meeting(title: "Sessie RAG-architecturen ", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Sessie RAG-architecturen - Prep.md")
        try "# Prep".write(to: prepURL, atomically: true, encoding: .utf8)

        let markdown = MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults)

        XCTAssertEqual(markdown, "# Prep")
    }

    func testCanonicalMeetingTodoTargetPrefersPrepFileOverNotesFile() throws {
        let defaults = makeScratchDefaults(label: "prep-canonical")
        let vaultURL = makeScratchVault("prep")
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        let notesURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Notes.md")
        FileManager.default.createFile(atPath: prepURL.path, contents: Data())
        FileManager.default.createFile(atPath: notesURL.path, contents: Data())

        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))

        XCTAssertEqual(files.canonicalTodoWriteURL.path, prepURL.path)
    }

    func testPrepURLReturnsNilInLocalMode() {
        let defaults = makeScratchDefaults(label: "prep-local")
        defaults.set("/tmp/vault", forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let meeting = Meeting(title: "Sync", date: .now)
        XCTAssertNil(MeetingPrepService.prepURL(for: meeting, userDefaults: defaults))
    }

    func testLoadPrepMarkdownReturnsNilInLocalMode() {
        let defaults = makeScratchDefaults(label: "prep-local")
        defaults.set("/tmp/vault", forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let meeting = Meeting(title: "Sync", date: .now)
        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    func testHasPrepReturnsFalseInLocalMode() {
        let defaults = makeScratchDefaults(label: "prep-local")
        defaults.set("/tmp/vault", forKey: AppPreferenceKey.obsidianVaultPath)
        assertScratchVault(defaults)
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let meeting = Meeting(title: "Sync", date: .now)
        XCTAssertFalse(MeetingPrepService.hasPrep(for: meeting, userDefaults: defaults))
    }

    private func makeDate() -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 4
        components.day = 12
        components.hour = 12
        return components.date!
    }
}
