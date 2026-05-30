import XCTest
@testable import Casablanca

final class MeetingSearchIndexTests: XCTestCase {
    func test_matchesTitleSummaryTranscriptAndPerson() {
        let m = Meeting(title: "Wegiz BgZ kickoff", date: .now)
        m.participants = ["Kim Owen-Jones", "Manon Koevoets"]
        m.summary = "Aligned on the BgZ exchange timeline."
        m.transcript = "the BgZ profile needs the FHIR mapping"
        let results = MeetingSearchIndex.search("bgz", in: [m])
        XCTAssertTrue(results.contains { $0.kind == .title })
        XCTAssertTrue(results.contains { $0.kind == .summary })
        XCTAssertTrue(results.contains { $0.kind == .transcript })

        let people = MeetingSearchIndex.search("kim", in: [m])
        XCTAssertTrue(people.contains { $0.kind == .person })
    }

    func test_snippetHighlightsMatch() {
        let m = Meeting(title: "Sync", date: .now)
        m.summary = "We aligned on the BgZ exchange timeline today."
        let r = MeetingSearchIndex.search("bgz", in: [m]).first { $0.kind == .summary }
        XCTAssertNotNil(r?.snippet)
        XCTAssertTrue(r!.snippet!.lowercased().contains("bgz"))
    }

    func test_caseInsensitiveAndEmptyQuery() {
        let m = Meeting(title: "Sync", date: .now)
        XCTAssertTrue(MeetingSearchIndex.search("", in: [m]).isEmpty)
        XCTAssertTrue(MeetingSearchIndex.search("   ", in: [m]).isEmpty)
    }
}
