import Foundation
import XCTest
@testable import Casablanca

final class AskCitationsTests: XCTestCase {

    // MARK: - Helpers

    private var nextID = 0

    private func source(_ meetingID: UUID, title: String, date: String, time: String? = nil,
                        kind: AskChunkKind = .transcript) -> AskSource {
        nextID += 1
        return AskSource(id: nextID, meetingID: meetingID, meetingTitle: title, dateLabel: date,
                         timeLabel: time, kind: kind, text: "x")
    }

    private func citations(_ segments: [AskAnswerSegment]) -> [AskCitation] {
        segments.flatMap { segment -> [AskCitation] in
            if case let .citations(_, list) = segment { return list }
            return []
        }
    }

    private func linkRuns(_ text: AttributedString) -> [(String, URL)] {
        text.runs.compactMap { run in
            guard let link = run.link else { return nil }
            return (String(text[run.range].characters), link)
        }
    }

    // MARK: - Parsing and resolution

    func testSingleCitationResolves() {
        let id = UUID()
        let sources = [source(id, title: "T", date: "2026-11-03", time: "12:34")]
        let segments = AskCitations.segments(in: "Besloten [T, 2026-11-03, 12:34].", sources: sources)
        XCTAssertEqual(segments, [
            .text("Besloten "),
            .citations(raw: "[T, 2026-11-03, 12:34]", [
                AskCitation(title: "T", dateLabel: "2026-11-03", timeLabel: "12:34",
                            target: AskCitationTarget(meetingID: id, seconds: 754))
            ]),
            .text(".")
        ])
    }

    func testCitationWithoutTime() {
        let id = UUID()
        let sources = [source(id, title: "T", date: "2026-11-03", kind: .summary)]
        let found = citations(AskCitations.segments(in: "Ja [T, 2026-11-03]", sources: sources))
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.timeLabel)
        XCTAssertEqual(found.first?.target, AskCitationTarget(meetingID: id, seconds: nil))
    }

    func testHourLabel() {
        let id = UUID()
        let sources = [source(id, title: "T", date: "2026-11-03", time: "1:02:03")]
        let found = citations(AskCitations.segments(in: "[T, 2026-11-03, 1:02:03]", sources: sources))
        XCTAssertEqual(found.first?.timeLabel, "1:02:03")
        XCTAssertEqual(found.first?.target?.seconds, 3723)
    }

    func testTitleWithCommaParses() {
        let id = UUID()
        let other = UUID()
        let sources = [source(id, title: "Bila Youri, Martijn", date: "2026-11-03", time: "05:00"),
                       source(other, title: "Standup", date: "2026-11-03")]
        let found = citations(AskCitations.segments(in: "[Bila Youri, Martijn, 2026-11-03, 05:00]", sources: sources))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.title, "Bila Youri, Martijn")
        XCTAssertEqual(found.first?.target, AskCitationTarget(meetingID: id, seconds: 300))
    }

    func testBracketsInTitleAreSanitised() {
        let id = UUID()
        let other = UUID()
        let sources = [source(id, title: AskCitationFormat.citationTitle("Sync [extern]"), date: "2026-11-03"),
                       source(other, title: "Standup", date: "2026-11-03")]
        let found = citations(AskCitations.segments(in: "Zie [Sync (extern), 2026-11-03].", sources: sources))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.target?.meetingID, id)
    }

    func testSemicolonSeparatedCitations() {
        let a = UUID()
        let b = UUID()
        let sources = [source(a, title: "A", date: "2026-11-03", time: "00:10"),
                       source(b, title: "B", date: "2026-11-04")]
        let segments = AskCitations.segments(in: "Ja [A, 2026-11-03, 00:10; B, 2026-11-04].", sources: sources)
        let groups = segments.filter { if case .citations = $0 { return true }; return false }
        XCTAssertEqual(groups.count, 1)
        guard case let .citations(raw, list)? = groups.first else { return XCTFail("no citations") }
        XCTAssertEqual(raw, "[A, 2026-11-03, 00:10; B, 2026-11-04]")
        XCTAssertEqual(list.map(\.target?.meetingID), [a, b])
        XCTAssertEqual(list.map(\.target?.seconds), [10, nil])
    }

    func testCitationNotInSourcesIsUnresolved() {
        let sources = [source(UUID(), title: "T", date: "2026-11-03")]
        let segments = AskCitations.segments(in: "Nee [Other, 2026-10-01, 01:00].", sources: sources)
        let found = citations(segments)
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.target)

        let rendered = AskCitations.attributed(segments)
        XCTAssertTrue(linkRuns(rendered.text).isEmpty)
        XCTAssertTrue(rendered.targets.isEmpty)
        XCTAssertEqual(String(rendered.text.characters), "Nee [Other, 2026-10-01, 01:00].")
    }

    func testSameDateUniqueFallback() {
        let id = UUID()
        let sources = [source(id, title: "Refinement Team Link", date: "2026-11-03", time: "00:05"),
                       source(id, title: "Refinement Team Link", date: "2026-11-03", kind: .summary),
                       source(UUID(), title: "Other", date: "2026-11-04")]
        let found = citations(AskCitations.segments(in: "[Refinement Link, 2026-11-03, 00:05]", sources: sources))
        XCTAssertEqual(found.first?.target, AskCitationTarget(meetingID: id, seconds: 5))
    }

    func testSameDateAmbiguousIsUnresolved() {
        let sources = [source(UUID(), title: "Standup", date: "2026-11-03"),
                       source(UUID(), title: "Refinement", date: "2026-11-03")]
        let found = citations(AskCitations.segments(in: "[Unknown, 2026-11-03]", sources: sources))
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.target)
    }

    func testSameTitleAndDateOnTwoMeetingsIsUnresolved() {
        let sources = [source(UUID(), title: "Standup", date: "2026-11-03"),
                       source(UUID(), title: "Standup", date: "2026-11-03")]
        let found = citations(AskCitations.segments(in: "[Standup, 2026-11-03]", sources: sources))
        XCTAssertNil(found.first?.target)
    }

    func testPlainBracketsAndBareTimestampsStayText() {
        let sources = [source(UUID(), title: "T", date: "2026-11-03")]
        for answer in ["a [x] b", "a [12:34] b", "a [TODO, later] b", "a [T, 2026-11-03; x] b", "a [] b"] {
            XCTAssertEqual(AskCitations.segments(in: answer, sources: sources), [.text(answer)], answer)
        }
    }

    func testCaseAndDiacriticInsensitiveTitle() {
        let id = UUID()
        let sources = [source(id, title: "Cafe Sync", date: "2026-11-03"),
                       source(UUID(), title: "Standup", date: "2026-11-03")]
        let found = citations(AskCitations.segments(in: "[café sync, 2026-11-03]", sources: sources))
        XCTAssertEqual(found.first?.target?.meetingID, id)
    }

    func testAdjacentTextIsMergedAndEmptyAnswer() {
        XCTAssertEqual(AskCitations.segments(in: "", sources: []), [])
        XCTAssertEqual(AskCitations.segments(in: "a [x] b [y] c", sources: []), [.text("a [x] b [y] c")])
    }

    func testSameDateDifferentTitleIsUnresolved() {
        let sources = [source(UUID(), title: "Refinement Team Link", date: "2026-11-03", time: "00:05")]
        let segments = AskCitations.segments(in: "[Budget review, 2026-11-03, 00:05]", sources: sources)
        XCTAssertNil(citations(segments).first?.target)
        XCTAssertTrue(AskCitations.attributed(segments).targets.isEmpty)
    }

    func testSameDateStopwordOnlyTitleIsUnresolved() {
        let sources = [source(UUID(), title: "Standup", date: "2026-11-03")]
        let found = citations(AskCitations.segments(in: "[De, 2026-11-03]", sources: sources))
        XCTAssertNil(found.first?.target)
    }

    func testTitleSimilarity() {
        XCTAssertTrue(AskCitations.titlesAreSimilar("Refinement Link", "Refinement Team Link"))
        XCTAssertTrue(AskCitations.titlesAreSimilar("Sync met Kim", "Partner sync Kim"))          // subset
        XCTAssertTrue(AskCitations.titlesAreSimilar("Weekly partner sync", "Partner sync Kim"))   // 2/4
        XCTAssertFalse(AskCitations.titlesAreSimilar("Weekly partner review", "Partner sync Kim")) // 1/5
        XCTAssertFalse(AskCitations.titlesAreSimilar("Budget review", "Refinement Team Link"))
    }

    /// Documented choice: an out-of-range time still resolves the meeting,
    /// but without a jump time.
    func testOutOfRangeTimeResolvesMeetingWithoutSeconds() {
        let id = UUID()
        let sources = [source(id, title: "T", date: "2026-11-03")]
        for time in ["99:99", "1:60:00", "12:60"] {
            let found = citations(AskCitations.segments(in: "[T, 2026-11-03, \(time)]", sources: sources))
            XCTAssertEqual(found.first?.timeLabel, time)
            XCTAssertEqual(found.first?.target, AskCitationTarget(meetingID: id, seconds: nil), time)
        }
        for (time, seconds) in [("59:59", 3599.0), ("1:59:59", 7199.0)] {
            let found = citations(AskCitations.segments(in: "[T, 2026-11-03, \(time)]", sources: sources))
            XCTAssertEqual(found.first?.target, AskCitationTarget(meetingID: id, seconds: seconds), time)
        }
    }

    func testUnterminatedAndNestedBracketsStayText() {
        let sources = [source(UUID(), title: "T", date: "2026-11-03")]
        for answer in [
            "a [T, 2026-11-03 b",
            "a T, 2026-11-03] b",
            "a [[T, 2026-11-03]] b",
            "a [zie [T, 2026-11-03] hier] b",
            "a [open [T, 2026-11-03] b",
        ] {
            XCTAssertEqual(AskCitations.segments(in: answer, sources: sources), [.text(answer)], answer)
        }
        // An unterminated '[' only affects its own line.
        let segments = AskCitations.segments(in: "a [open\nb [T, 2026-11-03]", sources: sources)
        XCTAssertEqual(segments.first, .text("a [open\nb "))
        XCTAssertNotNil(citations(segments).first?.target)
    }

    func testAllUnresolvedGroupRendersRawText() {
        let sources = [source(UUID(), title: "T", date: "2026-11-03")]
        let answer = "Ja [Ghost, 2020-01-01, 01:00; Other, 2021-02-02]."
        let segments = AskCitations.segments(in: answer, sources: sources)
        XCTAssertEqual(citations(segments).count, 2)
        XCTAssertTrue(citations(segments).allSatisfy { $0.target == nil })
        let rendered = AskCitations.attributed(segments)
        XCTAssertEqual(String(rendered.text.characters), answer)
        XCTAssertTrue(linkRuns(rendered.text).isEmpty)
        XCTAssertTrue(rendered.targets.isEmpty)
    }

    // MARK: - Links

    func testURLRoundTrip() {
        XCTAssertEqual(AskCitations.url(for: 7).absoluteString, "casablanca-ask://citation/7")
        XCTAssertEqual(AskCitations.index(from: AskCitations.url(for: 7)), 7)
        XCTAssertNil(AskCitations.index(from: URL(string: "https://x")!))
        XCTAssertNil(AskCitations.index(from: URL(string: "casablanca-ask://citation/abc")!))
        XCTAssertNil(AskCitations.index(from: URL(string: "casablanca-ask://other/7")!))
        XCTAssertNil(AskCitations.index(from: URL(string: "casablanca-ask://citation/-1")!))
    }

    func testAttributedLinksOnlyResolved() {
        let id = UUID()
        let sources = [source(id, title: "A", date: "2026-11-03", time: "00:10")]
        let answer = "Ja [A, 2026-11-03, 00:10; Ghost, 2020-01-01]."
        let rendered = AskCitations.attributed(AskCitations.segments(in: answer, sources: sources))

        XCTAssertEqual(String(rendered.text.characters), answer)
        let links = linkRuns(rendered.text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(rendered.targets.count, 1)
        guard let (label, url) = links.first, let index = AskCitations.index(from: url) else {
            return XCTFail("no resolved link")
        }
        XCTAssertEqual(label, "A, 2026-11-03, 00:10")
        XCTAssertEqual(rendered.targets[index], AskCitationTarget(meetingID: id, seconds: 10))
    }

    func testAttributedDistinctIndicesPerCitation() {
        let a = UUID()
        let b = UUID()
        let sources = [source(a, title: "A", date: "2026-11-03"), source(b, title: "B", date: "2026-11-04")]
        let rendered = AskCitations.attributed(
            AskCitations.segments(in: "[A, 2026-11-03] en [B, 2026-11-04; A, 2026-11-03]", sources: sources))
        let indices = linkRuns(rendered.text).compactMap { AskCitations.index(from: $0.1) }
        XCTAssertEqual(indices.count, 3)
        XCTAssertEqual(Set(indices).count, 3)
        XCTAssertEqual(indices.map { rendered.targets[$0]?.meetingID }, [a, b, a])
    }
}
