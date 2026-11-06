import XCTest
@testable import Casablanca

final class TranscriptLineFormatTests: XCTestCase {

    // MARK: - parse

    func testParsesPlainOldLine() throws {
        let line = try XCTUnwrap(TranscriptLineFormat.parse("[01:05] hallo"))
        XCTAssertEqual(line.label, "01:05")
        XCTAssertEqual(line.seconds, 65)
        XCTAssertNil(line.speaker)
        XCTAssertEqual(line.text, "hallo")
    }

    func testParsesHourLabel() throws {
        let line = try XCTUnwrap(TranscriptLineFormat.parse("[1:02:03] x"))
        XCTAssertEqual(line.label, "1:02:03")
        XCTAssertEqual(line.seconds, 3723)
        XCTAssertEqual(line.text, "x")
    }

    func testParsesKnownSpeaker() throws {
        let line = try XCTUnwrap(
            TranscriptLineFormat.parse("[00:10] Youri: ja", knownSpeakers: ["Youri"])
        )
        XCTAssertEqual(line.seconds, 10)
        XCTAssertEqual(line.speaker, "Youri")
        XCTAssertEqual(line.text, "ja")
    }

    func testColonTextIsNotSpeakerWhenUnknown() throws {
        let line = try XCTUnwrap(
            TranscriptLineFormat.parse("[00:10] Agenda: punt 1", knownSpeakers: [])
        )
        XCTAssertNil(line.speaker)
        XCTAssertEqual(line.text, "Agenda: punt 1")
    }

    func testParseWithoutKnownSpeakersNeverReturnsSpeaker() throws {
        let line = try XCTUnwrap(TranscriptLineFormat.parse("[00:10] Youri: ja"))
        XCTAssertNil(line.speaker)
        XCTAssertEqual(line.text, "Youri: ja")
    }

    func testParseReturnsNilWithoutLeadingTimestamp() {
        XCTAssertNil(TranscriptLineFormat.parse("hallo [00:10] daar"))
        XCTAssertNil(TranscriptLineFormat.parse(""))
    }

    func testSecondsFromLabel() {
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "00:00"), 0)
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "12:34"), 754)
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "1:02:03"), 3723)
        XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: "abc"))
        XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: "12"))
    }

    // MARK: - render

    func testRenderUsesDisplayNames() {
        let speakers = [
            SpeakerInfo(id: "mic", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
            SpeakerInfo(id: "s1", displayName: "Spreker 1", source: .system, isUser: false, nameConfirmed: false),
        ]
        let segments = [
            SpeakerSegment(start: 5, end: 7, speakerID: "mic", text: "Goedemorgen", words: nil),
            SpeakerSegment(start: 3725, end: 3730, speakerID: "s1", text: "Hoi", words: nil),
        ]
        XCTAssertEqual(
            TranscriptLineFormat.render(segments, speakers: speakers),
            "[00:05] Youri: Goedemorgen\n[1:02:05] Spreker 1: Hoi"
        )
    }

    func testRenderOmitsPrefixForNilSpeaker() {
        let speakers = [
            SpeakerInfo(id: "mic", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
        ]
        let segments = [
            SpeakerSegment(start: 0, end: 1, speakerID: nil, text: "zonder spreker", words: nil),
            SpeakerSegment(start: 2, end: 3, speakerID: "unknown-id", text: "onbekend", words: nil),
        ]
        XCTAssertEqual(
            TranscriptLineFormat.render(segments, speakers: speakers),
            "[00:00] zonder spreker\n[00:02] onbekend"
        )
    }

    // MARK: - renameSpeaker

    func testRenameOnlyTouchesPrefix() {
        let transcript = """
        [00:01] Spreker 1: Ik noem Spreker 1: zo even.
        [00:05] Youri: Wie is Spreker 1: eigenlijk?
        Spreker 1: geen timestamp
        """
        let expected = """
        [00:01] Kim: Ik noem Spreker 1: zo even.
        [00:05] Youri: Wie is Spreker 1: eigenlijk?
        Spreker 1: geen timestamp
        """
        XCTAssertEqual(
            TranscriptLineFormat.renameSpeaker(in: transcript, from: "Spreker 1", to: "Kim"),
            expected
        )
    }

    func testRenamePreservesHandEdits() {
        // A hand-edited transcript (corrected words, an inserted note line,
        // trailing whitespace) must come back byte-identical apart from the prefix.
        let transcript = "[00:01] Spreker 1: Medicore  heeft  Wegiz.\n"
            + "Notitie van Youri, handmatig toegevoegd\n"
            + "[01:10] Spreker 2: Klopt   \n"
            + "[1:00:00] Spreker 1: Einde"
        let expected = "[00:01] Arriejanne: Medicore  heeft  Wegiz.\n"
            + "Notitie van Youri, handmatig toegevoegd\n"
            + "[01:10] Spreker 2: Klopt   \n"
            + "[1:00:00] Arriejanne: Einde"
        XCTAssertEqual(
            TranscriptLineFormat.renameSpeaker(in: transcript, from: "Spreker 1", to: "Arriejanne"),
            expected
        )
    }

    // MARK: - timestampLabel

    func testTimestampLabelMatchesLegacyFormatter() {
        // Values pinned from TranscriptionService's formatter before the move.
        let expected: [(Double, String)] = [
            (0, "00:00"), (59.9, "00:59"), (3599, "59:59"), (3600, "1:00:00"),
        ]
        for (seconds, label) in expected {
            XCTAssertEqual(TranscriptLineFormat.timestampLabel(seconds: seconds), label, "\(seconds)")
            let legacy = TranscriptSegment(startTime: seconds, endTime: seconds + 1, text: "x")
            XCTAssertEqual(legacy.formattedTimestamp, "[\(label)]", "\(seconds)")
        }
    }

    // MARK: - SpeakerData

    func testDecodeGarbageIsEmpty() {
        XCTAssertEqual(SpeakerData.decodeSegments(nil), [])
        XCTAssertEqual(SpeakerData.decodeSegments(Data("not json".utf8)), [])
        XCTAssertEqual(SpeakerData.decodeSpeakers(nil), [])
        XCTAssertEqual(SpeakerData.decodeSpeakers(Data("{\"x\":1}".utf8)), [])
    }

    func testSpeakerDataRoundTrip() {
        let segments = [
            SpeakerSegment(
                start: 1, end: 2.5, speakerID: "mic", text: "hallo",
                words: [TranscriptWord(start: 1, end: 1.4, text: "hallo")]
            ),
            SpeakerSegment(start: 3, end: 4, speakerID: nil, text: "x", words: nil),
        ]
        let speakers = [
            SpeakerInfo(id: "mic", displayName: "Ik", source: .microphone, isUser: true, nameConfirmed: false),
            SpeakerInfo(id: "room", displayName: "Anderen", source: .room, isUser: false, nameConfirmed: false),
        ]
        XCTAssertEqual(SpeakerData.decodeSegments(SpeakerData.encodeSegments(segments)), segments)
        XCTAssertEqual(SpeakerData.decodeSpeakers(SpeakerData.encodeSpeakers(speakers)), speakers)
    }

    // MARK: - Robustness (review fix round)

    func testSecondsFromLabelRejectsOverlongComponents() {
        XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: "999999999999999999:1"))
        XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: "999999999999999999999:00"))
        XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: "123:45"))
        XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: "12:3"))
        XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: "1:2:03"))
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "5:07"), 307)
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "10:02:03"), 36123)
    }

    /// Strict: minutes and seconds must be < 60 (in `mm:ss` the first field
    /// is minutes); hours are unbounded. Non-strict stays as it was.
    func testStrictSecondsBoundMinutesAndSeconds() {
        for label in ["99:99", "60:00", "12:60", "1:60:00", "1:00:60", "garbage", "[03:10]"] {
            XCTAssertNil(TranscriptLineFormat.seconds(fromLabel: label, strict: true), label)
        }
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "03:10", strict: true), 190)
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "59:59", strict: true), 3599)
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "1:59:59", strict: true), 7199)
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "99:02:03", strict: true), 356_523, "hours are unbounded")
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "99:99"), 6039, "non-strict is unchanged")
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "99:99", strict: false), 6039)
        XCTAssertEqual(TranscriptLineFormat.seconds(fromLabel: "1:60:00"), 7200)
    }

    func testRenameLeavesOverflowingLabelLineUnchanged() {
        let transcript = "[999999999999999999:1] Spreker 1: x\n[00:02] Spreker 1: y"
        XCTAssertEqual(
            TranscriptLineFormat.renameSpeaker(in: transcript, from: "Spreker 1", to: "Kim"),
            "[999999999999999999:1] Spreker 1: x\n[00:02] Kim: y"
        )
    }

    func testRenameHandlesCRLFTranscript() {
        let transcript = "[00:01] Spreker 1: a\r\n[00:02] Youri: b\r\n[00:03] Spreker 1: c\n[00:04] Spreker 1:\r\n"
        XCTAssertEqual(
            TranscriptLineFormat.renameSpeaker(in: transcript, from: "Spreker 1", to: "Kim"),
            "[00:01] Kim: a\r\n[00:02] Youri: b\r\n[00:03] Kim: c\n[00:04] Kim:\r\n"
        )
    }

    func testRenameKeepsTrailingNewline() {
        XCTAssertEqual(
            TranscriptLineFormat.renameSpeaker(in: "[00:01] Spreker 1: a\n", from: "Spreker 1", to: "Kim"),
            "[00:01] Kim: a\n"
        )
    }

    func testRenamePrefixWithEmptyText() {
        let transcript = "[00:10] Spreker 1:\n[00:11] Spreker 1: \n[00:12] Spreker 1:x"
        XCTAssertEqual(
            TranscriptLineFormat.renameSpeaker(in: transcript, from: "Spreker 1", to: "Kim"),
            "[00:10] Kim:\n[00:11] Kim: \n[00:12] Spreker 1:x"
        )
    }

    func testRenameWithoutSpaceAfterTimestamp() {
        XCTAssertEqual(
            TranscriptLineFormat.renameSpeaker(in: "[00:10]Spreker 1: a", from: "Spreker 1", to: "Kim"),
            "[00:10]Kim: a"
        )
    }

    func testParsesKnownSpeakerWithEmptyText() throws {
        for raw in ["[00:10] Youri:", "[00:10] Youri: "] {
            let line = try XCTUnwrap(TranscriptLineFormat.parse(raw, knownSpeakers: ["Youri"]), raw)
            XCTAssertEqual(line.speaker, "Youri", raw)
            XCTAssertEqual(line.text, "", raw)
        }
        let unknown = try XCTUnwrap(TranscriptLineFormat.parse("[00:10] Youri:"))
        XCTAssertNil(unknown.speaker)
        XCTAssertEqual(unknown.text, "Youri:")
    }

    func testParsesLineWithoutSpaceAfterTimestamp() throws {
        // Documented behaviour: the space after `]` is optional.
        let line = try XCTUnwrap(TranscriptLineFormat.parse("[00:10]text"))
        XCTAssertEqual(line.label, "00:10")
        XCTAssertEqual(line.seconds, 10)
        XCTAssertNil(line.speaker)
        XCTAssertEqual(line.text, "text")
        let spoken = try XCTUnwrap(TranscriptLineFormat.parse("[00:10]Youri: ja", knownSpeakers: ["Youri"]))
        XCTAssertEqual(spoken.speaker, "Youri")
        XCTAssertEqual(spoken.text, "ja")
    }

    func testTimestampLabelClampsHugeValues() {
        XCTAssertFalse(TranscriptLineFormat.timestampLabel(seconds: 1e30).isEmpty)
        XCTAssertFalse(TranscriptLineFormat.timestampLabel(seconds: -1e30).isEmpty)
        XCTAssertFalse(TranscriptLineFormat.timestampLabel(seconds: Double(Int.max)).isEmpty)
        XCTAssertEqual(TranscriptLineFormat.timestampLabel(seconds: 36000), "10:00:00")
        XCTAssertEqual(TranscriptLineFormat.timestampLabel(seconds: .nan), "00:00")
    }

    // MARK: - sanitizedSpeakerName

    func testSanitizedSpeakerNameStripsColonAndBrackets() {
        XCTAssertEqual(TranscriptLineFormat.sanitizedSpeakerName("  Dr. A: B  "), "Dr. A B")
        XCTAssertEqual(TranscriptLineFormat.sanitizedSpeakerName("[Kim]"), "Kim")
        XCTAssertEqual(TranscriptLineFormat.sanitizedSpeakerName("Kim\t\n Owen-Jones"), "Kim Owen-Jones")
        XCTAssertEqual(TranscriptLineFormat.sanitizedSpeakerName(" : [ ] "), "")
        XCTAssertEqual(TranscriptLineFormat.sanitizedSpeakerName(""), "")
    }

    func testSanitizedSpeakerNameTruncatesTo40() {
        let long = String(repeating: "a", count: 50)
        XCTAssertEqual(TranscriptLineFormat.sanitizedSpeakerName(long).count, 40)
        // A cut that lands on a space does not leave a trailing space.
        let spaced = String(repeating: "b", count: 39) + " cdef"
        XCTAssertEqual(TranscriptLineFormat.sanitizedSpeakerName(spaced), String(repeating: "b", count: 39))
    }

    func testRenameWithInvalidNameRoundTripsThroughParse() throws {
        let transcript = "[00:10] Spreker 1: hallo"
        let renamed = TranscriptLineFormat.renameSpeaker(in: transcript, from: "Spreker 1", to: "Dr. A: B")
        let sanitized = TranscriptLineFormat.sanitizedSpeakerName("Dr. A: B")
        XCTAssertEqual(renamed, "[00:10] Dr. A B: hallo")
        let line = try XCTUnwrap(TranscriptLineFormat.parse(renamed, knownSpeakers: [sanitized]))
        XCTAssertEqual(line.speaker, sanitized)
        XCTAssertEqual(line.text, "hallo")
    }

    func testRenameToEmptySanitizedNameIsNoOp() {
        let transcript = "[00:10] Spreker 1: hallo"
        XCTAssertEqual(TranscriptLineFormat.renameSpeaker(in: transcript, from: "Spreker 1", to: " : "), transcript)
    }

    func testRenderSanitizesDisplayName() {
        let speakers = [
            SpeakerInfo(id: "s1", displayName: "Dr. A: B", source: .system, isUser: false, nameConfirmed: true),
            SpeakerInfo(id: "s2", displayName: "[ ]", source: .system, isUser: false, nameConfirmed: false),
        ]
        let segments = [
            SpeakerSegment(start: 1, end: 2, speakerID: "s1", text: "ja", words: nil),
            SpeakerSegment(start: 3, end: 4, speakerID: "s2", text: "nee", words: nil),
        ]
        XCTAssertEqual(
            TranscriptLineFormat.render(segments, speakers: speakers),
            "[00:01] Dr. A B: ja\n[00:03] nee"
        )
    }
}
