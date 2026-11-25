import XCTest
@testable import Casablanca

final class MeetingSearchIndexTests: XCTestCase {
    func test_matchesTitleSummaryTranscriptAndPerson() {
        let m = Meeting(title: "Lorem IpS kickoff", date: .now)
        m.participants = ["Kim Hartman-Lee", "Manon Wolters"]
        m.summary = "Aligned on the IpS exchange timeline."
        m.transcript = "the IpS profile needs the ELIT mapping"
        let results = MeetingSearchIndex.search("ips", in: [m])
        XCTAssertTrue(results.contains { $0.kind == .title })
        XCTAssertTrue(results.contains { $0.kind == .summary })
        XCTAssertTrue(results.contains { $0.kind == .transcript })

        let people = MeetingSearchIndex.search("kim", in: [m])
        XCTAssertTrue(people.contains { $0.kind == .person })
    }

    func test_snippetHighlightsMatch() {
        let m = Meeting(title: "Sync", date: .now)
        m.summary = "We aligned on the IpS exchange timeline today."
        let r = MeetingSearchIndex.search("ips", in: [m]).first { $0.kind == .summary }
        XCTAssertNotNil(r?.snippet)
        XCTAssertTrue(r!.snippet!.lowercased().contains("ips"))
    }

    func test_caseInsensitiveAndEmptyQuery() {
        let m = Meeting(title: "Sync", date: .now)
        XCTAssertTrue(MeetingSearchIndex.search("", in: [m]).isEmpty)
        XCTAssertTrue(MeetingSearchIndex.search("   ", in: [m]).isEmpty)
    }

    func test_matchesTag() {
        let m = Meeting(title: "Weekly", date: .now)
        m.setTags(["lorem", "nimbus"])
        let results = MeetingSearchIndex.search("nimb", in: [m])
        XCTAssertTrue(results.contains { $0.kind == .tag && $0.meeting.id == m.id })
    }

    func test_tagMatchYieldsSingleResultPerMeeting() {
        let m = Meeting(title: "Weekly", date: .now)
        m.setTags(["lorem-a", "lorem-b"]) // both contain "lorem"
        let tagResults = MeetingSearchIndex.search("lorem", in: [m]).filter { $0.kind == .tag }
        XCTAssertEqual(tagResults.count, 1)
    }
}
