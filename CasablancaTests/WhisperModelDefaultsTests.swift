import XCTest
@testable import Casablanca

final class WhisperModelDefaultsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WhisperModelDefaultsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private var storedModel: String? {
        defaults.string(forKey: AppPreferenceKey.whisperModel)
    }

    func testLegacyDefaultIsTodaysFallback() {
        XCTAssertEqual(WhisperModelDefaults.legacyDefault, "openai_whisper-base")
        XCTAssertEqual(WhisperModelDefaults.legacyDefault, AppPreferenceValue.defaultWhisperModel)
    }

    func testExistingInstallPinsLegacyDefault() {
        // Every signal of an existing install, each on its own.
        WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: true)
        XCTAssertEqual(storedModel, WhisperModelDefaults.legacyDefault, "store on disk")

        for key in [
            AppPreferenceKey.llmProvider,
            AppPreferenceKey.obsidianVaultPath,
            AppPreferenceKey.terminologyList,
        ] {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set("x", forKey: key)
            WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: false)
            XCTAssertEqual(storedModel, WhisperModelDefaults.legacyDefault, key)
        }

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: AppPreferenceKey.hasCompletedOnboarding)
        WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: false)
        XCTAssertEqual(storedModel, WhisperModelDefaults.legacyDefault, "onboarding completed")
    }

    func testNewInstallGetsNewDefault() {
        WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: false)
        XCTAssertEqual(storedModel, WhisperModelDefaults.newInstallDefault)
    }

    func testExplicitChoiceUntouched() {
        defaults.set("openai_whisper-small", forKey: AppPreferenceKey.whisperModel)
        WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: false)
        XCTAssertEqual(storedModel, "openai_whisper-small")

        WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: true)
        XCTAssertEqual(storedModel, "openai_whisper-small")
    }

    func testIdempotent() {
        WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: false)
        let first = storedModel
        // A second launch now looks like an existing install (the store and
        // onboarding exist), but the first pin must stand.
        defaults.set(true, forKey: AppPreferenceKey.hasCompletedOnboarding)
        WhisperModelDefaults.pinIfNeeded(defaults: defaults, storeExists: true)
        XCTAssertEqual(storedModel, first)
        XCTAssertEqual(storedModel, WhisperModelDefaults.newInstallDefault)
    }

    @MainActor
    func testNewInstallDefaultIsOffered() {
        let ids = TranscriptionService.availableWhisperModels.map(\.id)
        XCTAssertTrue(ids.contains(WhisperModelDefaults.newInstallDefault))
        XCTAssertTrue(ids.contains(WhisperModelDefaults.legacyDefault))
    }
}
