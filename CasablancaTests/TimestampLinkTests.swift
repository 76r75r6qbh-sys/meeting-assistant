import XCTest
@testable import Casablanca

/// `[mm:ss]` / `[h:mm:ss]` labels as links (Task 2.1, point 8): finding them
/// outside code, their link URLs, and the jump they request.
@MainActor
final class TimestampLinkTests: XCTestCase {
    private let meetingID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!

    private func labels(_ text: String) -> [String] {
        TimestampLinks.ranges(in: text).map { String(text[$0.range]) }
    }

    // MARK: - Finding labels

    func testFindsMinuteAndHourLabels() {
        let text = "Besluit genomen [12:34], later bevestigd [1:02:03] en [00:05].\n- **Kim** — offerte [10:02:03]"
        XCTAssertEqual(labels(text), ["[12:34]", "[1:02:03]", "[00:05]", "[10:02:03]"])
    }

    func testIgnoresNonTimestampBrackets() {
        for text in [
            "[x]", "[ ]", "[12:345]", "[1:2]", "[123:45]", "[12:34:5]", "[12:34 ]",
            "[12-34]", "[:12]", "[12:]", "[1:02:03:04]", "[a12:34]", "12:34", "[１２:３４]",
        ] {
            XCTAssertEqual(labels(text), [], "\(text) is not a timestamp label")
        }
        XCTAssertEqual(labels("- [x] taak [00:42]"), ["[00:42]"])
    }

    func testSecondsValues() {
        let expected: [(String, Double)] = [
            ("[00:00]", 0), ("[05:07]", 307), ("[5:07]", 307), ("[12:34]", 754),
            ("[59:59]", 3599), ("[1:02:03]", 3723), ("[10:02:03]", 36123),
        ]
        for (label, seconds) in expected {
            let found = TimestampLinks.ranges(in: "voor \(label) na")
            XCTAssertEqual(found.count, 1, label)
            XCTAssertEqual(found.first?.seconds, seconds, label)
            // Same grammar and values as the transcript line format.
            let bare = String(label.dropFirst().dropLast())
            XCTAssertEqual(found.first?.seconds, TranscriptLineFormat.seconds(fromLabel: bare), label)
        }
    }

    func testIgnoresTimestampsInCodeSpans() {
        XCTAssertEqual(labels("`[12:34]` maar wel [00:10]"), ["[00:10]"])
        XCTAssertEqual(labels("``a ` [01:00] b`` en [02:00]"), ["[02:00]"])
        XCTAssertEqual(labels("`log [00:01]` `[00:02]` [00:03]"), ["[00:03]"])
        // An unclosed backtick is literal, so the label is a link.
        XCTAssertEqual(labels("een ` los [00:05]"), ["[00:05]"])
        // A code span does not run over a line break here.
        XCTAssertEqual(labels("`open\n[00:06] `"), ["[00:06]"])
    }

    func testIgnoresTimestampsInFencedCodeBlocks() {
        let text = """
        Voor [00:01]
        ```swift
        let t = "[00:02]"
        ```
        Tussen [00:03]
          ~~~
        [00:04]
        ```
        [00:05] binnen tilde-fence, backticks sluiten hem niet
        ~~~
        Na [00:06]
        """
        XCTAssertEqual(labels(text), ["[00:01]", "[00:03]", "[00:06]"])
        // An unclosed fence runs to the end.
        XCTAssertEqual(labels("[00:01]\n```\n[00:02]"), ["[00:01]"])
    }

    // MARK: - Links

    func testURLRoundTrip() throws {
        let url = TimestampLinks.url(meetingID: meetingID, seconds: 3723)
        XCTAssertEqual(url.scheme, TimestampLinks.urlScheme)
        let target = try XCTUnwrap(TimestampLinks.target(from: url))
        XCTAssertEqual(target.meetingID, meetingID)
        XCTAssertEqual(target.seconds, 3723)
    }

    func testRejectsForeignAndMalformedURLs() {
        let id = meetingID.uuidString
        for string in [
            "https://example.com/\(id)?t=1",
            "casablanca-ask://citation/0",
            "\(TimestampLinks.urlScheme)://jump/not-a-uuid?t=1",
            "\(TimestampLinks.urlScheme)://jump/\(id)",
            "\(TimestampLinks.urlScheme)://jump/\(id)?t=-1",
            "\(TimestampLinks.urlScheme)://jump/\(id)?t=abc",
            "\(TimestampLinks.urlScheme)://other/\(id)?t=1",
        ] {
            XCTAssertNil(TimestampLinks.target(from: URL(string: string)!), string)
        }
    }

    func testAttributedLinksOnlyTheLabels() {
        let text = "Kim stuurt de offerte [12:34] (`[00:01]`) en belt [1:00:00]."
        let attributed = TimestampLinks.attributed(text, meetingID: meetingID)
        XCTAssertEqual(String(attributed.characters), text, "Linking must not change the text")

        var linked: [(String, URL)] = []
        for run in attributed.runs {
            if let link = run.link {
                linked.append((String(attributed[run.range].characters), link))
            }
        }
        XCTAssertEqual(linked.map(\.0), ["[12:34]", "[1:00:00]"])
        XCTAssertEqual(linked.map(\.1), [
            TimestampLinks.url(meetingID: meetingID, seconds: 754),
            TimestampLinks.url(meetingID: meetingID, seconds: 3600),
        ])
    }

    func testAddingLinksKeepsExistingAttributesAndHandlesWideCharacters() {
        var base = AttributedString("👩🏽‍💻 Besluit ")
        var bold = AttributedString("[00:30]")
        bold.inlinePresentationIntent = .stronglyEmphasized
        base += bold
        base += AttributedString(" — é [01:00]")

        let linked = TimestampLinks.addingLinks(to: base, meetingID: meetingID)
        let runs = linked.runs.compactMap { run -> (String, Bool)? in
            guard run.link != nil else { return nil }
            return (String(linked[run.range].characters), run.inlinePresentationIntent == .stronglyEmphasized)
        }
        XCTAssertEqual(runs.map(\.0), ["[00:30]", "[01:00]"])
        XCTAssertEqual(runs.map(\.1), [true, false], "The bold label stays bold")
    }

    func testNoMeetingMeansNoLinks() {
        let attributed = TimestampLinks.attributed("Zie [00:10]", meetingID: nil)
        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
    }

    // MARK: - Navigator

    func testJumpPublishesARequestAndCompletingClearsIt() throws {
        let navigator = MeetingDetailNavigator()
        XCTAssertNil(navigator.pendingJump)

        navigator.jump(to: meetingID, seconds: 754)
        let first = try XCTUnwrap(navigator.pendingJump)
        XCTAssertEqual(first.meetingID, meetingID)
        XCTAssertEqual(first.seconds, 754)

        // A second click on the same label is a new request.
        navigator.jump(to: meetingID, seconds: 754)
        let second = try XCTUnwrap(navigator.pendingJump)
        XCTAssertNotEqual(first, second)

        // Completing a stale request leaves the newer one pending.
        navigator.complete(first)
        XCTAssertEqual(navigator.pendingJump, second)
        navigator.complete(second)
        XCTAssertNil(navigator.pendingJump)
    }

    func testJumpClampsInvalidSeconds() {
        let navigator = MeetingDetailNavigator()
        navigator.jump(to: meetingID, seconds: -5)
        XCTAssertEqual(navigator.pendingJump?.seconds, 0)
        navigator.jump(to: meetingID, seconds: .nan)
        XCTAssertEqual(navigator.pendingJump?.seconds, 0)
    }

    func testNearestLineAtOrBeforeSeconds() {
        let starts: [Double] = [0, 10, 20, 20, 95]
        XCTAssertEqual(TimestampJumpPlan.lineIndex(atOrBefore: 15, starts: starts), 1)
        XCTAssertEqual(TimestampJumpPlan.lineIndex(atOrBefore: 10, starts: starts), 1)
        XCTAssertEqual(TimestampJumpPlan.lineIndex(atOrBefore: 20, starts: starts), 2, "First of equal starts")
        XCTAssertEqual(TimestampJumpPlan.lineIndex(atOrBefore: 5000, starts: starts), 4)
        XCTAssertEqual(TimestampJumpPlan.lineIndex(atOrBefore: 0, starts: starts), 0)
        // Before the first line: the first line.
        XCTAssertEqual(TimestampJumpPlan.lineIndex(atOrBefore: 3, starts: [7, 9]), 0)
        XCTAssertNil(TimestampJumpPlan.lineIndex(atOrBefore: 3, starts: []))
    }

    func testPlaysOnlyACompletedMeetingWithItsRecording() {
        XCTAssertTrue(TimestampJumpPlan.shouldPlay(status: .completed, isTranscribing: false, hasRecordingFile: true))
        XCTAssertFalse(TimestampJumpPlan.shouldPlay(status: .completed, isTranscribing: false, hasRecordingFile: false))
        XCTAssertFalse(TimestampJumpPlan.shouldPlay(status: .completed, isTranscribing: true, hasRecordingFile: true))
        for status in [MeetingStatus.recording, .pausedRecording, .processing, .upcoming, .notesOnly] {
            XCTAssertFalse(
                TimestampJumpPlan.shouldPlay(status: status, isTranscribing: false, hasRecordingFile: true),
                "\(status) must not play"
            )
        }
    }
}
