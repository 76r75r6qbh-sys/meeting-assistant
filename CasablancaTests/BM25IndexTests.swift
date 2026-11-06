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
        let idx = index([chunk("d0", "bgz profiel mapping"), chunk("d1", "lunch planning")])
        XCTAssertEqual(ids(idx.search("bgz", allowedMeetings: nil, limit: 10)), ["d0"])
    }

    func testRareTermOutweighsCommonTerm() {
        let idx = index([
            chunk("d0", "meeting agenda"),
            chunk("d1", "meeting notes"),
            chunk("d2", "meeting fhir"),
            chunk("d3", "fhir resources"),
        ])
        // d2 has both terms; among single-term docs the fhir doc must beat the meeting docs.
        let results = idx.search("meeting fhir", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(results.first?.chunk.id, "d2")
        XCTAssertEqual(ids(results).dropFirst().first, "d3")

        let idx2 = index([
            chunk("d0", "meeting agenda"),
            chunk("d1", "meeting notes"),
            chunk("d2", "meeting summary"),
            chunk("d3", "fhir resources"),
        ])
        XCTAssertEqual(idx2.search("meeting fhir", allowedMeetings: nil, limit: 10).first?.chunk.id, "d3")
    }

    func testTermFrequencySaturates() throws {
        let many = Array(repeating: "bgz", count: 10).joined(separator: " ")
        let one = "bgz alpha beta gamma delta epsilon zeta theta iota kappa"
        // All docs have 10 tokens, so |d| / avgdl = 1 and only tf differs.
        // (With k1 = 1.2 the "< 2x" bound holds only while |d| / avgdl < ~1.056.)
        let other = "lunch planning koffie thee taart soep brood kaas melk water"
        let idx = index([chunk("many", many), chunk("one", one), chunk("other", other)])
        let results = idx.search("bgz", allowedMeetings: nil, limit: 10)
        let scoreMany = try XCTUnwrap(results.first { $0.chunk.id == "many" }?.score)
        let scoreOne = try XCTUnwrap(results.first { $0.chunk.id == "one" }?.score)
        XCTAssertGreaterThan(scoreMany, scoreOne)
        XCTAssertLessThan(scoreMany, 2 * scoreOne)
    }

    func testLengthNormalisation() {
        let idx = index([
            chunk("long", "bgz alpha beta gamma delta"),
            chunk("short", "bgz alpha"),
            chunk("other", "lunch planning"),
        ])
        XCTAssertEqual(ids(idx.search("bgz", allowedMeetings: nil, limit: 10)), ["short", "long"])
    }

    func testIDFIsNonNegative() {
        let idx = index([chunk("d0", "bgz profiel"), chunk("d1", "bgz lunch"), chunk("d2", "bgz mapping")])
        let results = idx.search("bgz", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.score >= 0 })
        XCTAssertTrue(results.allSatisfy { $0.score > 0 })
    }

    func testAllowedMeetingsFilter() {
        let idx = index([
            chunk("a0", "bgz profiel", meeting: meetingA),
            chunk("a1", "bgz mapping", meeting: meetingA),
            chunk("b0", "bgz lunch", meeting: meetingB),
        ])
        let onlyB = idx.search("bgz", allowedMeetings: [meetingB], limit: 10)
        XCTAssertEqual(ids(onlyB), ["b0"])
        let onlyA = idx.search("bgz", allowedMeetings: [meetingA], limit: 10)
        XCTAssertEqual(Set(ids(onlyA)), ["a0", "a1"])
        XCTAssertEqual(idx.search("bgz", allowedMeetings: [], limit: 10), [])
        XCTAssertEqual(idx.search("bgz", allowedMeetings: nil, limit: 10).count, 3)
    }

    func testFilterDoesNotChangeStatistics() {
        let idx = index([
            chunk("a0", "bgz profiel", meeting: meetingA),
            chunk("b0", "bgz lunch", meeting: meetingB),
            chunk("b1", "lunch planning", meeting: meetingB),
        ])
        let all = idx.search("bgz", allowedMeetings: nil, limit: 10)
        let filtered = idx.search("bgz", allowedMeetings: [meetingA], limit: 10)
        XCTAssertEqual(filtered.first?.score, all.first { $0.chunk.id == "a0" }?.score)
    }

    func testLimitAndTieOrder() {
        let idx = index([chunk("c", "bgz profiel"), chunk("a", "bgz profiel"), chunk("b", "bgz profiel")])
        let results = idx.search("bgz", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(ids(results), ["a", "b", "c"])
        XCTAssertEqual(results[0].score, results[1].score)
        XCTAssertEqual(ids(idx.search("bgz", allowedMeetings: nil, limit: 1)), ["a"])
        XCTAssertEqual(idx.search("bgz", allowedMeetings: nil, limit: 0), [])
    }

    func testDiacriticQueryRetrievesUnaccentedDoc() {
        let idx = index([chunk("d0", "de klant is geinteresseerd in fhir"), chunk("d1", "lunch planning")])
        XCTAssertEqual(ids(idx.search("geïnteresseerd", allowedMeetings: nil, limit: 10)), ["d0"])
    }

    func testTitleBoost() {
        let chunks = [
            chunk("a0", "we bespreken de planning", meeting: meetingA),
            chunk("a1", "nog wat afspraken", meeting: meetingA),
            chunk("b0", "lunch en koffie", meeting: meetingB),
        ]
        let idx = BM25Index(chunks: chunks, titles: [meetingA: "Wegiz BgZ refinement", meetingB: "Teamuitje"])
        let results = idx.search("wegiz", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(Set(ids(results)), ["a0", "a1"])
    }

    func testEmptyQueryOrIndex() {
        let empty = index([])
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.search("bgz", allowedMeetings: nil, limit: 10), [])

        let idx = index([chunk("d0", "bgz profiel")])
        XCTAssertEqual(idx.count, 1)
        XCTAssertEqual(idx.search("", allowedMeetings: nil, limit: 10), [])
        XCTAssertEqual(idx.search("   ", allowedMeetings: nil, limit: 10), [])
        // Only stopwords → no query tokens.
        XCTAssertEqual(idx.search("de het een", allowedMeetings: nil, limit: 10), [])
        // Term absent from the index.
        XCTAssertEqual(idx.search("onbekend", allowedMeetings: nil, limit: 10), [])
    }

    func testManualScoreValue() throws {
        // d0 = "bgz profiel" (|d| = 2), d1 = "lunch" (|d| = 1); query "bgz".
        let idx = index([chunk("d0", "bgz profiel"), chunk("d1", "lunch")])
        let results = idx.search("bgz", allowedMeetings: nil, limit: 10)
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
        let idx = index([chunk("d0", "bgz profiel"), chunk("d1", "lunch")])
        let once = idx.search("bgz", allowedMeetings: nil, limit: 10)
        let twice = idx.search("bgz bgz", allowedMeetings: nil, limit: 10)
        XCTAssertEqual(once, twice)
    }
}
