import Foundation
import XCTest
@testable import Casablanca

final class ExportServiceTests: XCTestCase {
    func testExportRawNotesRendersFreeformBeforeTimestampedNotes() async throws {
        let vaultURL = makeTemporaryVaultURL()
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Freeform notes go here."
        meeting.timestampedNotes = [
            TimestampedNote(timestamp: 65, text: "Discussed rollout plan")
        ]

        let previousVaultPath = UserDefaults.standard.string(forKey: AppPreferenceKey.obsidianVaultPath)
        UserDefaults.standard.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        defer {
            if let previousVaultPath {
                UserDefaults.standard.set(previousVaultPath, forKey: AppPreferenceKey.obsidianVaultPath)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKey.obsidianVaultPath)
            }
        }

        let result = try await ExportService.exportRawNotes(meeting)
        guard case .obsidian(let export) = result else {
            return XCTFail("Expected obsidian destination by default")
        }
        let markdown = try String(contentsOf: export.notesURL, encoding: .utf8)

        let freeformRange = try XCTUnwrap(markdown.range(of: "## Freeform Notes"))
        let timestampedRange = try XCTUnwrap(markdown.range(of: "## Timestamped Notes"))

        XCTAssertLessThan(freeformRange.lowerBound, timestampedRange.lowerBound)
        XCTAssertTrue(markdown.contains("Freeform notes go here."))
        XCTAssertTrue(markdown.contains("- [01:05] Discussed rollout plan"))
    }

    func testExportRawNotesOmitsTimestampedSectionWhenNoTimestampedNotesExist() async throws {
        let vaultURL = makeTemporaryVaultURL()
        let meeting = Meeting(title: "Planning", date: .now)
        meeting.userNotes = "Only freeform notes"

        let previousVaultPath = UserDefaults.standard.string(forKey: AppPreferenceKey.obsidianVaultPath)
        UserDefaults.standard.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        defer {
            if let previousVaultPath {
                UserDefaults.standard.set(previousVaultPath, forKey: AppPreferenceKey.obsidianVaultPath)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKey.obsidianVaultPath)
            }
        }

        let result = try await ExportService.exportRawNotes(meeting)
        guard case .obsidian(let export) = result else {
            return XCTFail("Expected obsidian destination by default")
        }
        let markdown = try String(contentsOf: export.notesURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("## Freeform Notes"))
        XCTAssertFalse(markdown.contains("## Timestamped Notes"))
        XCTAssertFalse(markdown.contains("_No timestamped notes captured._"))
    }

    func testExportRawNotesKeepsTimestampedSectionWhenTimestampedNotesExist() async throws {
        let vaultURL = makeTemporaryVaultURL()
        let meeting = Meeting(title: "Retrospective", date: .now)
        meeting.timestampedNotes = [
            TimestampedNote(timestamp: 5, text: "Opened retro"),
            TimestampedNote(timestamp: 125, text: "Captured action items")
        ]

        let previousVaultPath = UserDefaults.standard.string(forKey: AppPreferenceKey.obsidianVaultPath)
        UserDefaults.standard.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        defer {
            if let previousVaultPath {
                UserDefaults.standard.set(previousVaultPath, forKey: AppPreferenceKey.obsidianVaultPath)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKey.obsidianVaultPath)
            }
        }

        let result = try await ExportService.exportRawNotes(meeting)
        guard case .obsidian(let export) = result else {
            return XCTFail("Expected obsidian destination by default")
        }
        let markdown = try String(contentsOf: export.notesURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("## Timestamped Notes"))
        XCTAssertTrue(markdown.contains("- [00:05] Opened retro"))
        XCTAssertTrue(markdown.contains("- [02:05] Captured action items"))
    }

    private func makeTemporaryVaultURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
