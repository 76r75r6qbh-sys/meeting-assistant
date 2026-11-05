import XCTest
@testable import Casablanca

@MainActor
final class SpeakerRenamerTests: XCTestCase {

    private func makeMeeting(
        transcript: String,
        raw: String? = nil,
        speakers: [SpeakerInfo],
        segments: [SpeakerSegment] = []
    ) -> Meeting {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.transcript = transcript
        meeting.rawTranscript = raw
        meeting.speakers = speakers
        meeting.speakerSegments = segments
        return meeting
    }

    private func cluster(_ id: String, _ name: String, source: SpeakerSource = .system) -> SpeakerInfo {
        SpeakerInfo(id: id, displayName: name, source: source, isUser: false, nameConfirmed: false)
    }

    func testRenameRewritesPrefixAndDisplayNameAndConfirms() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Speaker 1: Hello.\n[00:05] Me: Hi.\n[00:09] Speaker 1: Bye.",
            speakers: [
                SpeakerInfo(id: "me", displayName: "Me", source: .microphone, isUser: true, nameConfirmed: false),
                cluster("S1", "Speaker 1"),
            ]
        )

        let merged = try SpeakerRenamer.rename(speakerID: "S1", to: "Jan de Vries", in: meeting)

        XCTAssertFalse(merged)
        XCTAssertEqual(meeting.transcript, "[00:00] Jan de Vries: Hello.\n[00:05] Me: Hi.\n[00:09] Jan de Vries: Bye.")
        let renamed = try XCTUnwrap(meeting.speakers.first { $0.id == "S1" })
        XCTAssertEqual(renamed.displayName, "Jan de Vries")
        XCTAssertTrue(renamed.nameConfirmed)
        XCTAssertEqual(meeting.speakers.count, 2)
    }

    func testRenamePreservesHandEditedText() throws {
        // Line 2 was edited by hand (and the LLM corrected terms); "Spreker 1:"
        // also occurs inside text. Only the prefixes change.
        let transcript = """
        [00:00] Spreker 1: Welkom bij Team Link.
        [00:04] Spreker 1: Ik heb dit zelf aangepast, zei Spreker 1: echt waar.
        [00:08] Ik: Prima.
        Losse notitie zonder tijd: Spreker 1: blijft staan
        """
        let segments = [
            SpeakerSegment(start: 0, end: 4, speakerID: "S1", text: "Welkom bij tiem link.", words: nil),
            SpeakerSegment(start: 4, end: 8, speakerID: "S1", text: "Ik heb dit niet aangepast.", words: nil),
            SpeakerSegment(start: 8, end: 9, speakerID: "me", text: "Prima.", words: nil),
        ]
        let meeting = makeMeeting(
            transcript: transcript,
            speakers: [
                cluster("S1", "Spreker 1"),
                SpeakerInfo(id: "me", displayName: "Ik", source: .microphone, isUser: true, nameConfirmed: false),
            ],
            segments: segments
        )

        try SpeakerRenamer.rename(speakerID: "S1", to: "Kim", in: meeting)

        XCTAssertEqual(meeting.transcript, """
        [00:00] Kim: Welkom bij Team Link.
        [00:04] Kim: Ik heb dit zelf aangepast, zei Spreker 1: echt waar.
        [00:08] Ik: Prima.
        Losse notitie zonder tijd: Spreker 1: blijft staan
        """)
        XCTAssertEqual(meeting.speakerSegments, segments, "Segments are not touched by a plain rename")
    }

    func testRenameAlsoRewritesRawTranscript() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Speaker 1: Team Link.",
            raw: "[00:00] Speaker 1: tiem link.",
            speakers: [cluster("S1", "Speaker 1")]
        )

        try SpeakerRenamer.rename(speakerID: "S1", to: "Kim", in: meeting)

        XCTAssertEqual(meeting.transcript, "[00:00] Kim: Team Link.")
        XCTAssertEqual(meeting.rawTranscript, "[00:00] Kim: tiem link.")
    }

    func testRenameLeavesNilRawTranscriptNil() throws {
        let meeting = makeMeeting(transcript: "[00:00] Speaker 1: Hi.", speakers: [cluster("S1", "Speaker 1")])
        try SpeakerRenamer.rename(speakerID: "S1", to: "Kim", in: meeting)
        XCTAssertNil(meeting.rawTranscript)
    }

    func testRenameToExistingNameMergesSpeakers() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Kim: One.\n[00:05] Speaker 2: Two.\n[00:09] Kim: Three.",
            raw: "[00:00] Kim: One.\n[00:05] Speaker 2: Two.\n[00:09] Kim: Three.",
            speakers: [
                SpeakerInfo(id: "S1", displayName: "Kim", source: .system, isUser: false, nameConfirmed: true),
                cluster("S2", "Speaker 2"),
            ],
            segments: [
                SpeakerSegment(start: 0, end: 5, speakerID: "S1", text: "One.", words: nil),
                SpeakerSegment(start: 5, end: 9, speakerID: "S2", text: "Two.", words: nil),
                SpeakerSegment(start: 9, end: 12, speakerID: "S1", text: "Three.", words: nil),
            ]
        )

        let merged = try SpeakerRenamer.rename(speakerID: "S2", to: "Kim", in: meeting)

        XCTAssertTrue(merged)
        XCTAssertEqual(meeting.speakers.map(\.id), ["S1"])
        XCTAssertEqual(meeting.speakerSegments.map(\.speakerID), ["S1", "S1", "S1"])
        XCTAssertEqual(meeting.transcript, "[00:00] Kim: One.\n[00:05] Kim: Two.\n[00:09] Kim: Three.")
        XCTAssertEqual(meeting.rawTranscript, meeting.transcript)
    }

    func testMergeMatchesExistingNameCaseInsensitivelyAndKeepsItsSpelling() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Kim: One.\n[00:05] Speaker 2: Two.",
            speakers: [
                SpeakerInfo(id: "S1", displayName: "Kim", source: .system, isUser: false, nameConfirmed: true),
                cluster("S2", "Speaker 2"),
            ]
        )

        XCTAssertTrue(try SpeakerRenamer.rename(speakerID: "S2", to: "kim", in: meeting))
        XCTAssertEqual(meeting.transcript, "[00:00] Kim: One.\n[00:05] Kim: Two.")
    }

    func testEmptyNameRejected() {
        let meeting = makeMeeting(transcript: "[00:00] Speaker 1: Hi.", speakers: [cluster("S1", "Speaker 1")])

        XCTAssertThrowsError(try SpeakerRenamer.rename(speakerID: "S1", to: "  : [ ", in: meeting)) { error in
            XCTAssertEqual(error as? SpeakerRenamer.RenameError, .emptyName)
        }
        XCTAssertEqual(meeting.transcript, "[00:00] Speaker 1: Hi.")
        XCTAssertFalse(meeting.speakers[0].nameConfirmed)
    }

    func testUnknownSpeakerRejected() {
        let meeting = makeMeeting(transcript: "[00:00] Speaker 1: Hi.", speakers: [cluster("S1", "Speaker 1")])

        XCTAssertThrowsError(try SpeakerRenamer.rename(speakerID: "S9", to: "Kim", in: meeting)) { error in
            XCTAssertEqual(error as? SpeakerRenamer.RenameError, .unknownSpeaker)
        }
    }

    func testSanitizeStripsColonBracketAndCaps40() {
        XCTAssertEqual(SpeakerRenamer.sanitize("  Jan: [de] Vries  "), "Jan de Vries")
        XCTAssertEqual(SpeakerRenamer.sanitize(String(repeating: "a", count: 55)), String(repeating: "a", count: 40))
        XCTAssertEqual(SpeakerRenamer.sanitize(" \n "), "")
    }

    func testStoredDisplayNameIsSanitizedSoPrefixesStillParse() throws {
        let meeting = makeMeeting(transcript: "[00:00] Speaker 1: Hi.", speakers: [cluster("S1", "Speaker 1")])

        try SpeakerRenamer.rename(speakerID: "S1", to: " Kim: (PO) ", in: meeting)

        XCTAssertEqual(meeting.speakers[0].displayName, "Kim (PO)")
        let line = TranscriptLineFormat.parse(meeting.transcript ?? "", knownSpeakers: ["Kim (PO)"])
        XCTAssertEqual(line?.speaker, "Kim (PO)")
        XCTAssertEqual(line?.text, "Hi.")
    }

    func testMarkAsUserFlagsOneRoomClusterOnly() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Speaker 1: Hi.\n[00:03] Speaker 2: Hello.",
            speakers: [cluster("S1", "Speaker 1", source: .room), cluster("S2", "Speaker 2", source: .room)]
        )

        try SpeakerRenamer.setIsUser(true, speakerID: "S1", in: meeting)
        XCTAssertEqual(meeting.speakers.map(\.isUser), [true, false])

        try SpeakerRenamer.setIsUser(true, speakerID: "S2", in: meeting)
        XCTAssertEqual(meeting.speakers.map(\.isUser), [false, true], "Only one cluster can be the user")

        try SpeakerRenamer.setIsUser(false, speakerID: "S2", in: meeting)
        XCTAssertEqual(meeting.speakers.map(\.isUser), [false, false])
        XCTAssertEqual(meeting.transcript, "[00:00] Speaker 1: Hi.\n[00:03] Speaker 2: Hello.")
    }

    // MARK: - Review fixes

    func testRenameOntoAnotherSpeakersPlaceholderLabelDoesNotMerge() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Speaker 1: One.\n[00:05] Speaker 2: Two.",
            speakers: [cluster("S1", "Speaker 1"), cluster("S2", "Speaker 2")],
            segments: [
                SpeakerSegment(start: 0, end: 5, speakerID: "S1", text: "One.", words: nil),
                SpeakerSegment(start: 5, end: 9, speakerID: "S2", text: "Two.", words: nil),
            ]
        )

        XCTAssertFalse(try SpeakerRenamer.rename(speakerID: "S1", to: "Speaker 2", in: meeting))
        XCTAssertEqual(meeting.speakers.map(\.id), ["S1", "S2"], "A placeholder label is not a person to merge into")
        XCTAssertEqual(meeting.speakerSegments.map(\.speakerID), ["S1", "S2"])
    }

    func testRenameOntoTheUsersUnconfirmedNameMergesIntoTheUser() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Me: One.\n[00:05] Speaker 1: Two.",
            speakers: [
                SpeakerInfo(id: "me", displayName: "Me", source: .microphone, isUser: true, nameConfirmed: false),
                cluster("S1", "Speaker 1"),
            ],
            segments: [
                SpeakerSegment(start: 0, end: 5, speakerID: "me", text: "One.", words: nil),
                SpeakerSegment(start: 5, end: 9, speakerID: "S1", text: "Two.", words: nil),
            ]
        )

        XCTAssertTrue(try SpeakerRenamer.rename(speakerID: "S1", to: "me", in: meeting))
        XCTAssertEqual(meeting.speakers.map(\.id), ["me"])
        XCTAssertEqual(meeting.transcript, "[00:00] Me: One.\n[00:05] Me: Two.")
    }

    func testRenameJanLeavesJanWillemAlone() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Jan: Hoi.\n[00:04] Jan-Willem: Hallo Jan.\n[00:08] Jan Willem: Ook hoi.",
            speakers: [
                SpeakerInfo(id: "S1", displayName: "Jan", source: .system, isUser: false, nameConfirmed: false),
                SpeakerInfo(id: "S2", displayName: "Jan-Willem", source: .system, isUser: false, nameConfirmed: false),
                SpeakerInfo(id: "S3", displayName: "Jan Willem", source: .system, isUser: false, nameConfirmed: false),
            ]
        )

        try SpeakerRenamer.rename(speakerID: "S1", to: "Jan de Vries", in: meeting)
        XCTAssertEqual(meeting.transcript, "[00:00] Jan de Vries: Hoi.\n[00:04] Jan-Willem: Hallo Jan.\n[00:08] Jan Willem: Ook hoi.")

        try SpeakerRenamer.rename(speakerID: "S2", to: "Jan-Willem Bakker", in: meeting)
        XCTAssertEqual(meeting.transcript, "[00:00] Jan de Vries: Hoi.\n[00:04] Jan-Willem Bakker: Hallo Jan.\n[00:08] Jan Willem: Ook hoi.")
    }

    func testRenameKeepsCRLFLineEndings() throws {
        let meeting = makeMeeting(
            transcript: "[00:00] Speaker 1: Een.\r\n[00:05] Me: Twee.\r\n[00:09] Speaker 1:\r\n",
            raw: "[00:00] Speaker 1: een.\r\n",
            speakers: [cluster("S1", "Speaker 1")]
        )

        try SpeakerRenamer.rename(speakerID: "S1", to: "Kim", in: meeting)

        XCTAssertEqual(meeting.transcript, "[00:00] Kim: Een.\r\n[00:05] Me: Twee.\r\n[00:09] Kim:\r\n")
        XCTAssertEqual(meeting.rawTranscript, "[00:00] Kim: een.\r\n")
    }

    func testCrossSourceMergeRecordsEachMovedSegmentsSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerRenamerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpeakerAnalysisStore(directory: directory)
        let meeting = makeMeeting(
            transcript: "[00:00] Youri: One.\n[00:05] Speaker 1: Two.",
            speakers: [
                SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
                cluster("S1", "Speaker 1"),
            ],
            segments: [
                SpeakerSegment(start: 0, end: 2, speakerID: "me", text: "One.", words: nil),
                SpeakerSegment(start: 5, end: 14, speakerID: "S1", text: "Two.", words: nil),
            ]
        )

        XCTAssertTrue(try SpeakerRenamer.rename(speakerID: "S1", to: "Youri", in: meeting, store: store))

        let sources = try XCTUnwrap(store.load(meeting.id)?.segmentSources)
        XCTAssertEqual(sources, [SpeakerClipSelector.segmentKey(meeting.speakerSegments[1]): .system])
    }
}
