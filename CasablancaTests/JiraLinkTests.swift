import XCTest
@testable import Casablanca

/// Pure-logic tests for `JiraLink` URL construction.
final class JiraLinkTests: XCTestCase {

    func testURLForPlainKey() {
        let url = JiraLink.url(forKey: "ABC-1234")
        XCTAssertEqual(url?.absoluteString, "https://your-site.atlassian.net/browse/ABC-1234")
    }

    func testURLForKeyTrimsWhitespace() {
        let url = JiraLink.url(forKey: "  PROJ-7  ")
        XCTAssertEqual(url?.absoluteString, "https://your-site.atlassian.net/browse/PROJ-7")
    }

    func testURLForEmptyKeyIsNil() {
        XCTAssertNil(JiraLink.url(forKey: ""))
        XCTAssertNil(JiraLink.url(forKey: "   "))
    }

    func testURLForKeyWithSpaceIsNil() {
        XCTAssertNil(JiraLink.url(forKey: "ABC 1234"))
    }
}

extension JiraLinkTests {
    private func suite() -> UserDefaults {
        let suiteName = "CasablancaTests.\(UUID().uuidString)"
        let defaults = TestVaultGuard.makeScratchDefaults(suiteName: suiteName)
        addTeardownBlock { TestVaultGuard.removeScratchDefaults(defaults, suiteName: suiteName) }
        return defaults
    }

    func testConfiguredSiteIsUsed() {
        let defaults = suite()
        defaults.set("https://acme-corp.atlassian.net/", forKey: AppPreferenceKey.jiraSiteURL)
        XCTAssertEqual(
            JiraLink.url(forKey: "ABC-1", defaults: defaults)?.absoluteString,
            "https://acme-corp.atlassian.net/browse/ABC-1"
        )
    }

    func testInvalidSiteFallsBackToDefault() {
        let defaults = suite()
        defaults.set("not a url", forKey: AppPreferenceKey.jiraSiteURL)
        XCTAssertEqual(JiraLink.browseBase(defaults: defaults), JiraLink.defaultSiteURL + "/browse/")
    }
}
