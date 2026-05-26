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
}
