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
}
