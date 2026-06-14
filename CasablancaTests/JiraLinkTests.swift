import XCTest
@testable import Casablanca

/// Pure-logic tests for `JiraLink` URL construction.
final class JiraLinkTests: XCTestCase {

    func testURLForPlainKey() {
        let url = JiraLink.url(forKey: "IO-1234")
        XCTAssertEqual(url?.absoluteString, "https://tenzinger.atlassian.com/browse/IO-1234")
    }

    func testURLForKeyTrimsWhitespace() {
        let url = JiraLink.url(forKey: "  MCINT-7  ")
        XCTAssertEqual(url?.absoluteString, "https://tenzinger.atlassian.com/browse/MCINT-7")
    }

    func testURLForEmptyKeyIsNil() {
        XCTAssertNil(JiraLink.url(forKey: ""))
        XCTAssertNil(JiraLink.url(forKey: "   "))
    }

    func testURLForKeyWithSpaceIsNil() {
        XCTAssertNil(JiraLink.url(forKey: "IO 1234"))
    }

    func testURLFromTargetWithFullURL() {
        let target = "Story IO-99 at https://tenzinger.atlassian.com/browse/IO-99 needs review"
        let url = JiraLink.url(fromTarget: target)
        XCTAssertEqual(url?.absoluteString, "https://tenzinger.atlassian.com/browse/IO-99")
    }

    func testURLFromTargetWithIssueKeyOnly() {
        let url = JiraLink.url(fromTarget: "Refinement for IO-4321")
        XCTAssertEqual(url?.absoluteString, "https://tenzinger.atlassian.com/browse/IO-4321")
    }

    func testURLFromTargetJunkIsNil() {
        XCTAssertNil(JiraLink.url(fromTarget: "no key here"))
        XCTAssertNil(JiraLink.url(fromTarget: ""))
        XCTAssertNil(JiraLink.url(fromTarget: nil))
    }
}
