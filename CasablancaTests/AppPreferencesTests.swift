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

    func testNewSpeechPipelineDefaults() {
        let defaults = makeDefaults()
        AppPreferences.registerDefaults(in: defaults)

        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.recogniseSpeakersEnabled) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.keepSpeakerTracks) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.wordTimestampsEnabled) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.voiceProfilesEnabled) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.summaryTemplates), "")
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.autoAcceptVerifiedTodos) as? Bool, false)

        XCTAssertEqual(AppPreferenceKey.recogniseSpeakersEnabled, "recogniseSpeakersEnabled")
        XCTAssertEqual(AppPreferenceKey.keepSpeakerTracks, "keepSpeakerTracks")
        XCTAssertEqual(AppPreferenceKey.wordTimestampsEnabled, "wordTimestampsEnabled")
        XCTAssertEqual(AppPreferenceKey.voiceProfilesEnabled, "voiceProfilesEnabled")
        XCTAssertEqual(AppPreferenceKey.summaryTemplates, "summaryTemplates")
        XCTAssertEqual(AppPreferenceKey.autoAcceptVerifiedTodos, "autoAcceptVerifiedTodos")
    }

    /// Registered defaults live in the volatile registration domain: a value the
    /// user stored always wins, and registering never writes to the store.
    func testSpeechPipelineDefaultsNeverOverrideStoredValues() {
        let suite = UUID().uuidString
        let defaults = makeDefaults(suite: suite)
        defaults.set(false, forKey: AppPreferenceKey.recogniseSpeakersEnabled)

        AppPreferences.registerDefaults(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: AppPreferenceKey.recogniseSpeakersEnabled))
        // The registration domain is process-wide (the test host registered it
        // too), so check what was persisted: exactly the one value set above.
        // Fails both if registering wrote values and if the domain is unreadable.
        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(Set(persisted.keys), [AppPreferenceKey.recogniseSpeakersEnabled])
    }
}
