import XCTest
@testable import Casablanca

final class LLMProviderFactoryTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultReturnsOllamaProvider() {
        let defaults = makeDefaults()
        let provider = LLMProviderFactory.current(defaults: defaults)
        XCTAssertTrue(provider is OllamaProvider, "expected OllamaProvider, got \(type(of: provider))")
    }

    func testOMLXSelectionReturnsOMLXProvider() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        let provider = LLMProviderFactory.current(defaults: defaults)
        XCTAssertTrue(provider is OMLXProvider, "expected OMLXProvider, got \(type(of: provider))")
    }

    func testSequentialCallsReflectPreferenceChange() {
        let defaults = makeDefaults()
        XCTAssertTrue(LLMProviderFactory.current(defaults: defaults) is OllamaProvider)
        AppPreferences.setLLMProvider(.omlx, in: defaults)
        XCTAssertTrue(LLMProviderFactory.current(defaults: defaults) is OMLXProvider)
    }

    func testOllamaProviderReadsOllamaEndpointAndModel() {
        let defaults = makeDefaults()
        defaults.set("http://10.0.0.5:11434", forKey: AppPreferenceKey.ollamaEndpoint)
        defaults.set("custom-llama", forKey: AppPreferenceKey.ollamaModel)
        let provider = LLMProviderFactory.current(defaults: defaults) as? OllamaProvider
        XCTAssertEqual(provider?.endpoint, "http://10.0.0.5:11434")
        XCTAssertEqual(provider?.model, "custom-llama")
    }

    func testOMLXProviderReadsOMLXEndpointAndModel() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        defaults.set("http://10.0.0.5:8000/v1", forKey: AppPreferenceKey.omlxEndpoint)
        defaults.set("qwen", forKey: AppPreferenceKey.omlxModel)
        let provider = LLMProviderFactory.current(defaults: defaults) as? OMLXProvider
        XCTAssertEqual(provider?.endpoint, "http://10.0.0.5:8000/v1")
        XCTAssertEqual(provider?.model, "qwen")
    }

    func testOMLXProviderReadsAPIKey() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        defaults.set("my-key", forKey: AppPreferenceKey.omlxAPIKey)
        let provider = LLMProviderFactory.current(defaults: defaults) as? OMLXProvider
        XCTAssertEqual(provider?.apiKey, "my-key")
    }

    func testOMLXProviderDefaultsAPIKeyToEmpty() {
        let defaults = makeDefaults()
        defaults.set("omlx", forKey: AppPreferenceKey.llmProvider)
        let provider = LLMProviderFactory.current(defaults: defaults) as? OMLXProvider
        XCTAssertEqual(provider?.apiKey, "")
    }

    func testClaudeCodeSelectionReturnsClaudeCLIProvider() {
        let defaults = makeDefaults()
        defaults.set("claudeCode", forKey: AppPreferenceKey.llmProvider)
        let provider = LLMProviderFactory.current(defaults: defaults)
        XCTAssertTrue(provider is ClaudeCLIProvider, "expected ClaudeCLIProvider, got \(type(of: provider))")
    }

    func testClaudeCLIProviderReadsPathAndModel() {
        let defaults = makeDefaults()
        defaults.set("claudeCode", forKey: AppPreferenceKey.llmProvider)
        defaults.set("/opt/homebrew/bin/claude", forKey: AppPreferenceKey.claudeCLIPath)
        defaults.set("opus", forKey: AppPreferenceKey.claudeCLIModel)
        let provider = LLMProviderFactory.current(defaults: defaults) as? ClaudeCLIProvider
        XCTAssertEqual(provider?.endpoint, "/opt/homebrew/bin/claude")
        XCTAssertEqual(provider?.model, "opus")
    }

    /// First run: no path stored yet. Empty means "auto-detect on the next fetch",
    /// so it must not be substituted with a guess here.
    func testClaudeCLIProviderDefaultsPathToEmptyForAutoDetect() {
        let defaults = makeDefaults()
        defaults.set("claudeCode", forKey: AppPreferenceKey.llmProvider)
        let provider = LLMProviderFactory.current(defaults: defaults) as? ClaudeCLIProvider
        XCTAssertEqual(provider?.endpoint, "")
    }

    func testClaudeCLIProviderDefaultsModelToSonnet() {
        let defaults = makeDefaults()
        defaults.set("claudeCode", forKey: AppPreferenceKey.llmProvider)
        let provider = LLMProviderFactory.current(defaults: defaults) as? ClaudeCLIProvider
        XCTAssertEqual(provider?.model, "sonnet")
    }

    /// A stored-but-empty model would sail past `?? "sonnet"` and ship `--model ""`
    /// to the CLI, failing every call.
    func testClaudeCLIProviderTreatsStoredEmptyModelAsAbsent() {
        let defaults = makeDefaults()
        defaults.set("claudeCode", forKey: AppPreferenceKey.llmProvider)
        defaults.set("", forKey: AppPreferenceKey.claudeCLIModel)
        let provider = LLMProviderFactory.current(defaults: defaults) as? ClaudeCLIProvider
        XCTAssertEqual(provider?.model, "sonnet")
    }

    /// The provider writes its detected path back through `defaults`; handing it
    /// `.standard` instead would leak into the user's real preferences under test.
    func testClaudeCLIProviderReceivesTheInjectedDefaults() {
        let defaults = makeDefaults()
        defaults.set("claudeCode", forKey: AppPreferenceKey.llmProvider)
        let provider = LLMProviderFactory.current(defaults: defaults) as? ClaudeCLIProvider
        XCTAssertIdentical(provider?.defaults, defaults)
    }
}
