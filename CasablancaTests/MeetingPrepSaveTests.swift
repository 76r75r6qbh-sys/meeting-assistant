import Foundation
import XCTest
@testable import Casablanca

/// `MeetingPrepService.loadPrep` / `savePrep`: the prep editor writes back to
/// the file it loaded and keeps to-dos written to that file while it was open.
final class MeetingPrepSaveTests: XCTestCase {
    private var notesDirectory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        let vault = makeScratchVault("prep-save")
        defaults = makeScratchDefaults(vaultRoot: vault, label: "prep-save")
        defaults.set(PrepTodoStorage.obsidian.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        assertScratchVault(defaults)
        notesDirectory = vault.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
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

    func testSaveWritesBackToTheCandidateItWasLoadedFrom() throws {
        // Trailing space: the exact name keeps it, the normalized one does not.
        let meeting = Meeting(title: "Sessie RAG ", date: makeDate())
        let exactURL = notesDirectory.appendingPathComponent("2025-04-12 Sessie RAG  - Prep.md")
        let normalizedURL = notesDirectory.appendingPathComponent("2025-04-12 Sessie RAG - Prep.md")
        try "# Prep\n".write(to: normalizedURL, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(MeetingPrepService.loadPrep(for: meeting, userDefaults: defaults))
        XCTAssertEqual(loaded.sourceURL?.path, normalizedURL.path)

        try MeetingPrepService.savePrep("# Prep\nedited\n", loaded: loaded, for: meeting, userDefaults: defaults)

        XCTAssertEqual(try String(contentsOf: normalizedURL, encoding: .utf8), "# Prep\nedited\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exactURL.path))
    }

    func testSaveKeepsTodosAddedOnDiskWhileEditing() throws {
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try "## Goal\n\n## Action Items\n\n- [ ] Old <!-- casablanca-todo: AAAAAAAA-0000-0000-0000-000000000001 -->\n"
            .write(to: prepURL, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(MeetingPrepService.loadPrep(for: meeting, userDefaults: defaults))

        // Meanwhile summarization / a skill adds a todo to the file.
        let added = "- [ ] From summary <!-- casablanca-todo: BBBBBBBB-0000-0000-0000-000000000002 -->"
        try (loaded.markdown + added + "\n").write(to: prepURL, atomically: true, encoding: .utf8)

        let edited = loaded.markdown.replacingOccurrences(of: "## Goal\n", with: "## Goal\nShip it.\n")
        let saved = try MeetingPrepService.savePrep(edited, loaded: loaded, for: meeting, userDefaults: defaults)

        let onDisk = try String(contentsOf: prepURL, encoding: .utf8)
        XCTAssertEqual(onDisk, saved)
        XCTAssertTrue(onDisk.contains("Ship it."))
        XCTAssertTrue(onDisk.contains("- [ ] Old"))
        XCTAssertTrue(onDisk.contains(added))
    }

    func testSaveRespectsTodoDeletedInEditorAndTakesToggleFromDisk() throws {
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        let keep = "- [ ] Keep <!-- casablanca-todo: AAAAAAAA-0000-0000-0000-000000000001 -->"
        let drop = "- [ ] Drop <!-- casablanca-todo: BBBBBBBB-0000-0000-0000-000000000002 -->"
        try "## Action Items\n\n\(keep)\n\(drop)\n".write(to: prepURL, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(MeetingPrepService.loadPrep(for: meeting, userDefaults: defaults))

        // Keep gets ticked off in the app's todo list while the editor is open.
        try loaded.markdown.replacingOccurrences(of: "- [ ] Keep", with: "- [x] Keep")
            .write(to: prepURL, atomically: true, encoding: .utf8)

        let edited = loaded.markdown.replacingOccurrences(of: "\(drop)\n", with: "")
        try MeetingPrepService.savePrep(edited, loaded: loaded, for: meeting, userDefaults: defaults)

        XCTAssertEqual(
            try String(contentsOf: prepURL, encoding: .utf8),
            "## Action Items\n\n\(keep.replacingOccurrences(of: "- [ ]", with: "- [x]"))\n"
        )
    }

    func testUnchangedFileIsOverwrittenWithEditorTextVerbatim() throws {
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try "## Action Items\n\n- [ ] A\n".write(to: prepURL, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(MeetingPrepService.loadPrep(for: meeting, userDefaults: defaults))

        try MeetingPrepService.savePrep("rewritten", loaded: loaded, for: meeting, userDefaults: defaults)

        XCTAssertEqual(try String(contentsOf: prepURL, encoding: .utf8), "rewritten")
    }

    func testNewPrepWithoutFileIsCreatedAtCanonicalPath() throws {
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        XCTAssertNil(MeetingPrepService.loadPrep(for: meeting, userDefaults: defaults))

        try MeetingPrepService.savePrep("## Goal\n", loaded: nil, for: meeting, userDefaults: defaults)

        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        XCTAssertEqual(try String(contentsOf: prepURL, encoding: .utf8), "## Goal\n")
    }

    // The meeting-brief skill writes `- Prep.md` while the editor holds prep
    // loaded from `localPrepNotes`: saving must not replace the skill's prose.
    func testSaveNeverOverwritesAVaultPrepFileTheEditorDidNotLoad() throws {
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        meeting.localPrepNotes = "## Goal\nmine\n"
        let loaded = try XCTUnwrap(MeetingPrepService.loadPrep(for: meeting, userDefaults: defaults))
        XCTAssertNil(loaded.sourceURL)

        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        let brief = "# Brief\n\nLast discussed: the release.\n"
        try brief.write(to: prepURL, atomically: true, encoding: .utf8)

        let saved = try MeetingPrepService.savePrepAndReload(
            "## Goal\nmine, edited\n", loaded: loaded, for: meeting, userDefaults: defaults
        )

        let onDisk = try String(contentsOf: prepURL, encoding: .utf8)
        XCTAssertTrue(onDisk.hasPrefix("# Brief\n\nLast discussed: the release."), "Skill prose kept")
        XCTAssertTrue(onDisk.contains(MeetingPrepService.adoptedSeparator))
        XCTAssertTrue(onDisk.hasSuffix("## Goal\nmine, edited\n"), "Editor text appended")
        XCTAssertEqual(saved.markdown, onDisk)
        XCTAssertEqual(saved.adoptedVaultFile?.path, prepURL.path)
        XCTAssertEqual(saved.loaded, .init(markdown: onDisk, sourceURL: prepURL))
        XCTAssertEqual(meeting.localPrepNotes, "## Goal\nmine, edited\n")

        // From then on it is the editor's file: a second save writes it as is.
        let second = try MeetingPrepService.savePrepAndReload(
            saved.markdown + "more\n", loaded: saved.loaded, for: meeting, userDefaults: defaults
        )
        XCTAssertNil(second.adoptedVaultFile)
        XCTAssertEqual(try String(contentsOf: prepURL, encoding: .utf8), onDisk + "more\n")
    }

    func testSaveWithNothingLoadedKeepsAVaultPrepFileThatAppeared() throws {
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try "# Brief\n".write(to: prepURL, atomically: true, encoding: .utf8)

        try MeetingPrepService.savePrep("## Goal\n", loaded: nil, for: meeting, userDefaults: defaults)

        let onDisk = try String(contentsOf: prepURL, encoding: .utf8)
        XCTAssertTrue(onDisk.hasPrefix("# Brief"))
        XCTAssertTrue(onDisk.hasSuffix("## Goal\n"))
    }

    func testLocalModeSavesOnMeeting() throws {
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let meeting = Meeting(title: "Weekly Sync", date: makeDate())
        meeting.localPrepNotes = "before"
        let loaded = MeetingPrepService.loadPrep(for: meeting, userDefaults: defaults)
        XCTAssertEqual(loaded, .init(markdown: "before", sourceURL: nil))

        try MeetingPrepService.savePrep("after", loaded: loaded, for: meeting, userDefaults: defaults)

        XCTAssertEqual(meeting.localPrepNotes, "after")
    }
}
