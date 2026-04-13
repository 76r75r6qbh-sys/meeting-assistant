import Foundation
import XCTest
@testable import Casablanca

final class MeetingPrepServiceTests: XCTestCase {
    func testPrepURLUsesMeetingNotesFolderAndPrepSuffix() {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.path-\(UUID().uuidString)")!
        defaults.set("/tmp/obsidian-vault", forKey: AppPreferenceKey.obsidianVaultPath)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        let prepURL = MeetingPrepService.prepURL(for: meeting, userDefaults: defaults)

        XCTAssertEqual(
            prepURL?.path,
            "/tmp/obsidian-vault/meeting notes/2025-04-12 Weekly Sync - Prep.md"
        )
    }

    func testLoadPrepMarkdownReturnsContentsWhenPrepFileExists() throws {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.exists-\(UUID().uuidString)")!
        let vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try "# Agenda\n\n- Review roadmap".write(to: prepURL, atomically: true, encoding: .utf8)

        let markdown = MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults)

        XCTAssertEqual(markdown, "# Agenda\n\n- Review roadmap")
    }

    func testLoadPrepMarkdownReturnsNilWhenVaultPathMissing() {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.missing-vault-\(UUID().uuidString)")!
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        XCTAssertNil(MeetingPrepService.prepURL(for: meeting, userDefaults: defaults))
        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    func testLoadPrepMarkdownReturnsNilWhenPrepFileMissing() {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.missing-file-\(UUID().uuidString)")!
        defaults.set("/tmp/obsidian-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())

        XCTAssertNil(MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults))
    }

    func testLoadPrepMarkdownMatchesTrimmedPrepFilenameWhenMeetingTitleHasTrailingWhitespace() throws {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.trailing-space-\(UUID().uuidString)")!
        let vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)

        let meeting = Meeting(title: "Sessie RAG-architecturen ", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Sessie RAG-architecturen - Prep.md")
        try "# Prep".write(to: prepURL, atomically: true, encoding: .utf8)

        let markdown = MeetingPrepService.loadPrepMarkdown(for: meeting, userDefaults: defaults)

        XCTAssertEqual(markdown, "# Prep")
    }

    func testCanonicalMeetingTodoTargetPrefersPrepFileOverNotesFile() throws {
        let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.canonical-\(UUID().uuidString)")!
        let vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)

        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        let notesURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Notes.md")
        FileManager.default.createFile(atPath: prepURL.path, contents: Data())
        FileManager.default.createFile(atPath: notesURL.path, contents: Data())

        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))

        XCTAssertEqual(files.canonicalTodoWriteURL.path, prepURL.path)
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
