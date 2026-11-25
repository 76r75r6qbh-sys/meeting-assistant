import Foundation
import XCTest
@testable import Casablanca

final class BM25IndexTests: XCTestCase {

    // MARK: - Helpers

    private let meetingA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let meetingB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func chunk(_ id: String, _ text: String, meeting: UUID? = nil) -> AskChunk {
        AskChunk(id: id, meetingID: meeting ?? meetingA, kind: .transcript, text: text, timeLabel: nil)
    }

    /// Index without titles, so indexed text is only the chunk text.
    private func index(_ chunks: [AskChunk]) -> BM25Index {
        BM25Index(chunks: chunks, titles: [:])
    }

    private func ids(_ results: [ScoredChunk]) -> [String] {
        results.map(\.chunk.id)
    }

    // MARK: - Tests

    func testExactTermOutranksAbsent() {
        let idx = index([chunk("d0", "ips profiel mapping"), chunk("d1", "lunch planning")])
        XCTAssertEqual(ids(idx.search("ips", allowedMeetings: nil, limit: 10)), ["d0"])
    }

    func testRareTermOutweighsCommonTerm() {
        let idx = index([
            chunk("d0", "meeting agenda"),
            chunk("d1", "meeting notes"),
            chunk("d2", "meeting elit"),
            chunk("d3", "elit resources"),
        ])
        // d2 has both terms; among single-term docs the elit doc must beat the meeting docs.
        let results = idx.search("meeting elit", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(results.first?.chunk.id, "d2")
        XCTAssertEqual(ids(results).dropFirst().first, "d3")

        let idx2 = index([
            chunk("d0", "meeting agenda"),
            chunk("d1", "meeting notes"),
            chunk("d2", "meeting summary"),
            chunk("d3", "elit resources"),
        ])
        XCTAssertEqual(idx2.search("meeting elit", allowedMeetings: nil, limit: 10).first?.chunk.id, "d3")
    }

    func testTermFrequencySaturates() throws {
        let many = Array(repeating: "ips", count: 10).joined(separator: " ")
        let one = "ips alpha beta gamma delta epsilon zeta theta iota kappa"
        // All docs have 10 tokens, so |d| / avgdl = 1 and only tf differs.
        // (With k1 = 1.2 the "< 2x" bound holds only while |d| / avgdl < ~1.056.)
        let other = "lunch planning koffie thee taart soep brood kaas melk water"
        let idx = index([chunk("many", many), chunk("one", one), chunk("other", other)])
        let results = idx.search("ips", allowedMeetings: nil, limit: 10)
        let scoreMany = try XCTUnwrap(results.first { $0.chunk.id == "many" }?.score)
        let scoreOne = try XCTUnwrap(results.first { $0.chunk.id == "one" }?.score)
        XCTAssertGreaterThan(scoreMany, scoreOne)
        XCTAssertLessThan(scoreMany, 2 * scoreOne)
    }

    func testLengthNormalisation() {
        let idx = index([
            chunk("long", "ips alpha beta gamma delta"),
            chunk("short", "ips alpha"),
            chunk("other", "lunch planning"),
        ])
        XCTAssertEqual(ids(idx.search("ips", allowedMeetings: nil, limit: 10)), ["short", "long"])
    }

    func testIDFIsNonNegative() {
        let idx = index([chunk("d0", "ips profiel"), chunk("d1", "ips lunch"), chunk("d2", "ips mapping")])
        let results = idx.search("ips", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.score >= 0 })
        XCTAssertTrue(results.allSatisfy { $0.score > 0 })
    }

    func testAllowedMeetingsFilter() {
        let idx = index([
            chunk("a0", "ips profiel", meeting: meetingA),
            chunk("a1", "ips mapping", meeting: meetingA),
            chunk("b0", "ips lunch", meeting: meetingB),
        ])
        let onlyB = idx.search("ips", allowedMeetings: [meetingB], limit: 10)
        XCTAssertEqual(ids(onlyB), ["b0"])
        let onlyA = idx.search("ips", allowedMeetings: [meetingA], limit: 10)
        XCTAssertEqual(Set(ids(onlyA)), ["a0", "a1"])
        XCTAssertEqual(idx.search("ips", allowedMeetings: [], limit: 10), [])
        XCTAssertEqual(idx.search("ips", allowedMeetings: nil, limit: 10).count, 3)
    }

    func testFilterDoesNotChangeStatistics() {
        let idx = index([
            chunk("a0", "ips profiel", meeting: meetingA),
            chunk("b0", "ips lunch", meeting: meetingB),
            chunk("b1", "lunch planning", meeting: meetingB),
        ])
        let all = idx.search("ips", allowedMeetings: nil, limit: 10)
        let filtered = idx.search("ips", allowedMeetings: [meetingA], limit: 10)
        XCTAssertEqual(filtered.first?.score, all.first { $0.chunk.id == "a0" }?.score)
    }

    func testLimitAndTieOrder() {
        let idx = index([chunk("c", "ips profiel"), chunk("a", "ips profiel"), chunk("b", "ips profiel")])
        let results = idx.search("ips", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(ids(results), ["a", "b", "c"])
        XCTAssertEqual(results[0].score, results[1].score)
        XCTAssertEqual(ids(idx.search("ips", allowedMeetings: nil, limit: 1)), ["a"])
        XCTAssertEqual(idx.search("ips", allowedMeetings: nil, limit: 0), [])
    }

    func testDiacriticQueryRetrievesUnaccentedDoc() {
        let idx = index([chunk("d0", "de klant is geinteresseerd in elit"), chunk("d1", "lunch planning")])
        XCTAssertEqual(ids(idx.search("geïnteresseerd", allowedMeetings: nil, limit: 10)), ["d0"])
    }

    func testTitleBoost() {
        let chunks = [
            chunk("a0", "we bespreken de planning", meeting: meetingA),
            chunk("a1", "nog wat afspraken", meeting: meetingA),
            chunk("b0", "lunch en koffie", meeting: meetingB),
        ]
        let idx = BM25Index(chunks: chunks, titles: [meetingA: "Lorem IpS refinement", meetingB: "Teamuitje"])
        let results = idx.search("lorem", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(Set(ids(results)), ["a0", "a1"])
    }

    func testEmptyQueryOrIndex() {
        let empty = index([])
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.search("ips", allowedMeetings: nil, limit: 10), [])

        let idx = index([chunk("d0", "ips profiel")])
        XCTAssertEqual(idx.count, 1)
        XCTAssertEqual(idx.search("", allowedMeetings: nil, limit: 10), [])
        XCTAssertEqual(idx.search("   ", allowedMeetings: nil, limit: 10), [])
        // Only stopwords → no query tokens.
        XCTAssertEqual(idx.search("de het een", allowedMeetings: nil, limit: 10), [])
        // Term absent from the index.
        XCTAssertEqual(idx.search("onbekend", allowedMeetings: nil, limit: 10), [])
    }

    func testManualScoreValue() throws {
        // d0 = "ips profiel" (|d| = 2), d1 = "lunch" (|d| = 1); query "ips".
        let idx = index([chunk("d0", "ips profiel"), chunk("d1", "lunch")])
        let results = idx.search("ips", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(ids(results), ["d0"])

        let n = 2.0, df = 1.0, tf = 1.0, dl = 2.0, avgdl = 1.5
        let k1 = 1.2, b = 0.75
        let idf = log(1 + (n - df + 0.5) / (df + 0.5))
        let expected = idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * dl / avgdl))
        let score = try XCTUnwrap(results.first?.score)
        XCTAssertEqual(score, expected, accuracy: 1e-9)
        XCTAssertEqual(BM25Index.k1, 1.2)
        XCTAssertEqual(BM25Index.b, 0.75)
    }

    func testRepeatedQueryTermCountsOnce() {
        let idx = index([chunk("d0", "ips profiel"), chunk("d1", "lunch")])
        let once = idx.search("ips", allowedMeetings: nil, limit: 10)
        let twice = idx.search("ips ips", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(once, twice)
    }
}
