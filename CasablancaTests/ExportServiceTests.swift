import Foundation
import XCTest
@testable import Casablanca

final class ExportServiceTests: XCTestCase {
    func testExportRawNotesRendersFreeformSection() async throws {
        let vaultURL = makeTemporaryVaultURL()
        let meeting = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.userNotes = "Freeform notes go here."

        let previousVaultPath = UserDefaults.standard.string(forKey: AppPreferenceKey.obsidianVaultPath)
        let previousDestination = UserDefaults.standard.string(forKey: AppPreferenceKey.exportDestination)
        UserDefaults.standard.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        UserDefaults.standard.set(ExportDestination.obsidian.rawValue, forKey: AppPreferenceKey.exportDestination)
        defer {
            if let previousVaultPath {
                UserDefaults.standard.set(previousVaultPath, forKey: AppPreferenceKey.obsidianVaultPath)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKey.obsidianVaultPath)
            }
            if let previousDestination {
                UserDefaults.standard.set(previousDestination, forKey: AppPreferenceKey.exportDestination)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKey.exportDestination)
            }
        }

        let result = try await ExportService.exportRawNotes(meeting)
        guard case .obsidian(let export) = result else {
            return XCTFail("Expected obsidian destination by default")
        }
        let markdown = try String(contentsOf: export.notesURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("## Freeform Notes"))
        XCTAssertTrue(markdown.contains("Freeform notes go here."))
    }

    func testExportRawNotesUsesPlaceholderWhenNoFreeformNotesExist() async throws {
        let vaultURL = makeTemporaryVaultURL()
        let meeting = Meeting(title: "Planning", date: .now)

        let previousVaultPath = UserDefaults.standard.string(forKey: AppPreferenceKey.obsidianVaultPath)
        let previousDestination = UserDefaults.standard.string(forKey: AppPreferenceKey.exportDestination)
        UserDefaults.standard.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        UserDefaults.standard.set(ExportDestination.obsidian.rawValue, forKey: AppPreferenceKey.exportDestination)
        defer {
            if let previousVaultPath {
                UserDefaults.standard.set(previousVaultPath, forKey: AppPreferenceKey.obsidianVaultPath)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKey.obsidianVaultPath)
            }
            if let previousDestination {
                UserDefaults.standard.set(previousDestination, forKey: AppPreferenceKey.exportDestination)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKey.exportDestination)
            }
        }

        let result = try await ExportService.exportRawNotes(meeting)
        guard case .obsidian(let export) = result else {
            return XCTFail("Expected obsidian destination by default")
        }
        let markdown = try String(contentsOf: export.notesURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("## Freeform Notes"))
        XCTAssertTrue(markdown.contains("_No freeform notes captured._"))
    }

    private func makeTemporaryVaultURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
