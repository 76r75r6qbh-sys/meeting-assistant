import XCTest
@testable import Casablanca

/// Phase 9a: tag normalization + the pure helpers shared by add/filter/search.
final class MeetingTagsTests: XCTestCase {
    // MARK: - normalizeTag

    func test_normalizeTag_lowercasesAndTrims() {
        XCTAssertEqual(Meeting.normalizeTag("  Lorem  "), "lorem")
        XCTAssertEqual(Meeting.normalizeTag("Nimbus"), "nimbus")
    }

    func test_normalizeTag_returnsNilForEmptyOrWhitespace() {
        XCTAssertNil(Meeting.normalizeTag(""))
        XCTAssertNil(Meeting.normalizeTag("   "))
        XCTAssertNil(Meeting.normalizeTag("\n\t"))
    }

    // MARK: - normalizeTags (dedup + order)

    func test_normalizeTags_dedupesLowercasedTrimmedAndDropsEmpty() {
        let input = ["Lorem", "lorem ", "  LOREM", "Nimbus", "", "  ", "nimbus"]
        XCTAssertEqual(Meeting.normalizeTags(input), ["lorem", "nimbus"])
    }

    func test_normalizeTags_preservesFirstSeenOrder() {
        XCTAssertEqual(Meeting.normalizeTags(["b", "a", "c", "a"]), ["b", "a", "c"])
    }

    // MARK: - addTag / removeTag / setTags

    func test_addTag_normalizesAndPreventsDuplicates() {
        let m = Meeting(title: "X", date: .now)
        XCTAssertTrue(m.addTag("Lorem"))
        XCTAssertFalse(m.addTag("  lorem "), "Already present after normalization")
        XCTAssertFalse(m.addTag("   "), "Empty contributes nothing")
        XCTAssertEqual(m.tags, ["lorem"])
    }

    func test_removeTag() {
        let m = Meeting(title: "X", date: .now)
        m.setTags(["lorem", "nimbus"])
        m.removeTag("lorem")
        XCTAssertEqual(m.tags, ["nimbus"])
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
