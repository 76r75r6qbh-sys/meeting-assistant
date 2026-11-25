import XCTest
@testable import Casablanca

final class TranscriptPresentationTests: XCTestCase {

    func testEmptyTranscriptYieldsEmpty() {
        XCTAssertEqual(TranscriptPresentation.parse(""), .empty)
        XCTAssertEqual(TranscriptPresentation.parse("   \n  \t "), .empty)
    }

    func testUntimestampedTranscriptFallsBackToPlain() {
        let text = "Just some notes\nwith no timestamps at all."
        guard case .plain(let plain) = TranscriptPresentation.parse(text) else {
            return XCTFail("Expected .plain")
        }
        XCTAssertEqual(plain, text)
    }

    func testParsesTimestampMinutesSeconds() {
        XCTAssertEqual(TranscriptPresentation.parseTimestamp("00:00"), 0)
        XCTAssertEqual(TranscriptPresentation.parseTimestamp("01:30"), 90)
        XCTAssertEqual(TranscriptPresentation.parseTimestamp("12:05"), 725)
    }

    func testParsesTimestampHoursMinutesSeconds() {
        XCTAssertEqual(TranscriptPresentation.parseTimestamp("1:00:00"), 3600)
        XCTAssertEqual(TranscriptPresentation.parseTimestamp("1:02:03"), 3723)
    }

    func testRejectsMalformedTimestamp() {
        XCTAssertNil(TranscriptPresentation.parseTimestamp("abc"))
        XCTAssertNil(TranscriptPresentation.parseTimestamp("1:2:3:4"))
        XCTAssertNil(TranscriptPresentation.parseTimestamp("12"))
    }

    func testTimestampedTranscriptGroupsIntoFiveMinuteChapters() {
        let transcript = """
        [00:10] Opening remarks
        [02:30] Still in chapter one
        [05:01] New chapter begins
        [09:59] End of chapter two
        [11:00] Chapter three
        """
        guard case .chapters(let chapters) = TranscriptPresentation.parse(transcript) else {
            return XCTFail("Expected .chapters")
        }
        XCTAssertEqual(chapters.count, 3)

        XCTAssertEqual(chapters[0].startSeconds, 0)
        XCTAssertEqual(chapters[0].endSeconds, 300)
        XCTAssertEqual(chapters[0].segments.count, 2)
        XCTAssertEqual(chapters[0].segments.first?.text, "Opening remarks")

        XCTAssertEqual(chapters[1].startSeconds, 300)
        XCTAssertEqual(chapters[1].segments.count, 2)

        XCTAssertEqual(chapters[2].startSeconds, 600)
        XCTAssertEqual(chapters[2].segments.count, 1)
        XCTAssertEqual(chapters[2].segments.first?.text, "Chapter three")
    }

    func testChapterTitleFormatting() {
        let chapter = TranscriptPresentation.Chapter(startSeconds: 0, endSeconds: 300, segments: [])
        XCTAssertEqual(chapter.title, "00:00 – 05:00")

        let later = TranscriptPresentation.Chapter(startSeconds: 3600, endSeconds: 3900, segments: [])
        XCTAssertEqual(later.title, "1:00:00 – 1:05:00")
    }

    func testMixedLinesIgnoreUntimestampedLines() {
        let transcript = """
        [00:05] Real segment
        garbage line without timestamp
        [00:20] Another segment
        """
        guard case .chapters(let chapters) = TranscriptPresentation.parse(transcript) else {
            return XCTFail("Expected .chapters")
        }
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].segments.count, 2)
    }
}
