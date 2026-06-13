import XCTest
@testable import Casablanca

/// Phase 9a: tag normalization + the pure helpers shared by add/filter/search.
final class MeetingTagsTests: XCTestCase {
    // MARK: - normalizeTag

    func test_normalizeTag_lowercasesAndTrims() {
        XCTAssertEqual(Meeting.normalizeTag("  Wegiz  "), "wegiz")
        XCTAssertEqual(Meeting.normalizeTag("Orchestra"), "orchestra")
    }

    func test_normalizeTag_returnsNilForEmptyOrWhitespace() {
        XCTAssertNil(Meeting.normalizeTag(""))
        XCTAssertNil(Meeting.normalizeTag("   "))
        XCTAssertNil(Meeting.normalizeTag("\n\t"))
    }

    // MARK: - normalizeTags (dedup + order)

    func test_normalizeTags_dedupesLowercasedTrimmedAndDropsEmpty() {
        let input = ["Wegiz", "wegiz ", "  WEGIZ", "Orchestra", "", "  ", "orchestra"]
        XCTAssertEqual(Meeting.normalizeTags(input), ["wegiz", "orchestra"])
    }

    func test_normalizeTags_preservesFirstSeenOrder() {
        XCTAssertEqual(Meeting.normalizeTags(["b", "a", "c", "a"]), ["b", "a", "c"])
    }

    // MARK: - addTag / removeTag / setTags

    func test_addTag_normalizesAndPreventsDuplicates() {
        let m = Meeting(title: "X", date: .now)
        XCTAssertTrue(m.addTag("Wegiz"))
        XCTAssertFalse(m.addTag("  wegiz "), "Already present after normalization")
        XCTAssertFalse(m.addTag("   "), "Empty contributes nothing")
        XCTAssertEqual(m.tags, ["wegiz"])
    }

    func test_removeTag() {
        let m = Meeting(title: "X", date: .now)
        m.setTags(["wegiz", "orchestra"])
        m.removeTag("wegiz")
        XCTAssertEqual(m.tags, ["orchestra"])
    }

    func test_setTags_storesNormalized() {
        let m = Meeting(title: "X", date: .now)
        m.setTags(["  AI ", "ai", "Partnering"])
        XCTAssertEqual(m.tags, ["ai", "partnering"])
    }

    func test_defaultTagsIsEmpty() {
        let m = Meeting(title: "X", date: .now)
        XCTAssertEqual(m.tags, [])
    }
}
