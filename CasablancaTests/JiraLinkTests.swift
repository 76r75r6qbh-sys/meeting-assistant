import XCTest
@testable import Casablanca

/// Pure-logic tests for `JiraLink` URL construction.
final class JiraLinkTests: XCTestCase {

    func testURLForPlainKey() {
        let url = JiraLink.url(forKey: "IO-1234")
        XCTAssertEqual(url?.absoluteString, "https://tenzinger.atlassian.net/browse/IO-1234")
    }

    func testURLForKeyTrimsWhitespace() {
        let url = JiraLink.url(forKey: "  MCINT-7  ")
        XCTAssertEqual(url?.absoluteString, "https://tenzinger.atlassian.net/browse/MCINT-7")
    }

    func testURLForEmptyKeyIsNil() {
        XCTAssertNil(JiraLink.url(forKey: ""))
        XCTAssertNil(JiraLink.url(forKey: "   "))
    }

    func testURLForKeyWithSpaceIsNil() {
        XCTAssertNil(JiraLink.url(forKey: "IO 1234"))
    }
}
