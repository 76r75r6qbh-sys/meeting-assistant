import XCTest
@testable import Casablanca

final class AppPreferencesTests: XCTestCase {
    private func makeDefaults(suite: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testExportDestinationDefaultsToObsidian() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.exportDestination(in: defaults), .obsidian)
    }

    func testExportDestinationReadsStoredValue() {
        let defaults = makeDefaults()
        defaults.set("appleNotes", forKey: AppPreferenceKey.exportDestination)
        XCTAssertEqual(AppPreferences.exportDestination(in: defaults), .appleNotes)
    }

    func testPrepTodoStorageDefaultsToObsidian() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.prepTodoStorage(in: defaults), .obsidian)
    }

    func testPrepTodoStorageReadsStoredValue() {
        let defaults = makeDefaults()
        defaults.set("local", forKey: AppPreferenceKey.prepTodoStorage)
        XCTAssertEqual(AppPreferences.prepTodoStorage(in: defaults), .local)
    }

    func testAutoExportEnabledMigratesFromLegacyKey() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian)
        XCTAssertNil(defaults.object(forKey: AppPreferenceKey.autoExportEnabled))

        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: AppPreferenceKey.autoExportEnabled))
        XCTAssertTrue(defaults.bool(forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian))
    }

    func testAutoExportEnabledMigrationIsIdempotent() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian)
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)
        defaults.set(false, forKey: AppPreferenceKey.autoExportEnabled)

        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: AppPreferenceKey.autoExportEnabled))
    }

    func testAutoExportEnabledMigrationSkippedWhenNoLegacyValue() {
        let defaults = makeDefaults()
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded(in: defaults)
        XCTAssertNil(defaults.object(forKey: AppPreferenceKey.autoExportEnabled))
    }

    func testLLMProviderDefaultsToOllama() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.llmProvider(in: defaults), .ollama)
    }

    func testLLMProviderReadsStoredValue() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        XCTAssertEqual(AppPreferences.llmProvider(in: defaults), .omlx)
    }

    func testLLMProviderFallsBackOnUnknownValue() {
        let defaults = makeDefaults()
        defaults.set("garbage", forKey: AppPreferenceKey.llmProvider)
        XCTAssertEqual(AppPreferences.llmProvider(in: defaults), .ollama)
    }

    func testLLMProviderReadsClaudeCodeStoredValue() {
        let defaults = makeDefaults()
        defaults.set("claudeCode", forKey: AppPreferenceKey.llmProvider)
        XCTAssertEqual(AppPreferences.llmProvider(in: defaults), .claudeCode)
    }

    func testSetLLMProviderWritesRawValue() {
        let defaults = makeDefaults()
        AppPreferences.setLLMProvider(.omlx, in: defaults)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.llmProvider), "omlx")
    }

    /// The raw value is persisted user data: changing it would silently reset every
    /// existing Claude Code user back to Ollama on the next launch.
    func testSetLLMProviderWritesClaudeCodeRawValue() {
        let defaults = makeDefaults()
        AppPreferences.setLLMProvider(.claudeCode, in: defaults)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.llmProvider), "claudeCode")
    }
}
