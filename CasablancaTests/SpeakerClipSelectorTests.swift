import XCTest
@testable import Casablanca

@MainActor
final class SpeakerClipSelectorTests: XCTestCase {
    private var directory: URL!
    private var micURL: URL!
    private var systemURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerClipSelectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        micURL = directory.appendingPathComponent("mic.m4a")
        systemURL = directory.appendingPathComponent("system.m4a")
        try Data([0]).write(to: micURL)
        try Data([0]).write(to: systemURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeMeeting(segments: [SpeakerSegment]) -> Meeting {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.micTrackFileURL = micURL.path
        meeting.systemTrackFileURL = systemURL.path
        meeting.speakers = [
            SpeakerInfo(id: "me", displayName: "Me", source: .microphone, isUser: true, nameConfirmed: true),
            SpeakerInfo(id: "S1", displayName: "Speaker 1", source: .system, isUser: false, nameConfirmed: false),
            SpeakerInfo(id: "S2", displayName: "Speaker 2", source: .room, isUser: false, nameConfirmed: false),
        ]
        meeting.speakerSegments = segments
        return meeting
    }

    private func segment(_ start: Double, _ end: Double, _ id: String?) -> SpeakerSegment {
        SpeakerSegment(start: start, end: end, speakerID: id, text: "x", words: nil)
    }

    func testPicksLongestSegmentCappedAtFiveSeconds() {
        let meeting = makeMeeting(segments: [
            segment(0, 3, "S1"),
            segment(10, 22, "S1"), // longest: 12 s
            segment(30, 42, "S1"), // same length, later: loses the tie
            segment(50, 51, "me"),
        ])

        XCTAssertEqual(
            SpeakerClipSelector.clip(for: "S1", meeting: meeting),
            SpeakerClip(url: systemURL, start: 10, duration: 5)
        )
    }

    func testShortLongestSegmentKeepsItsLength() {
        let meeting = makeMeeting(segments: [segment(4, 6.5, "S1"), segment(8, 9, "S1")])
        XCTAssertEqual(
            SpeakerClipSelector.clip(for: "S1", meeting: meeting),
            SpeakerClip(url: systemURL, start: 4, duration: 2.5)
        )
    }

    func testSystemSpeakerUsesSystemTrack() {
        let meeting = makeMeeting(segments: [segment(0, 2, "S1")])
        XCTAssertEqual(SpeakerClipSelector.clip(for: "S1", meeting: meeting)?.url, systemURL)
    }

    func testMicSpeakerUsesMicTrack() {
        let meeting = makeMeeting(segments: [segment(0, 2, "me"), segment(3, 6, "S2")])
        XCTAssertEqual(SpeakerClipSelector.clip(for: "me", meeting: meeting)?.url, micURL)
        XCTAssertEqual(SpeakerClipSelector.clip(for: "S2", meeting: meeting)?.url, micURL, "Room speakers are on the mic track")
    }

    func testMissingTrackFileGivesNil() throws {
        let meeting = makeMeeting(segments: [segment(0, 2, "S1"), segment(3, 4, "me")])
        try FileManager.default.removeItem(at: systemURL)
        XCTAssertNil(SpeakerClipSelector.clip(for: "S1", meeting: meeting))

        meeting.micTrackFileURL = nil
        XCTAssertNil(SpeakerClipSelector.clip(for: "me", meeting: meeting), "Tracks deleted (keepSpeakerTracks off)")
    }

    func testUnknownSpeakerOrNoSegmentsGivesNil() {
        let meeting = makeMeeting(segments: [segment(0, 2, "S1")])
        XCTAssertNil(SpeakerClipSelector.clip(for: "S2", meeting: meeting))
        XCTAssertNil(SpeakerClipSelector.clip(for: "S9", meeting: meeting))
    }

    func testTalkTimeSharesSumToOne() throws {
        let shares = SpeakerClipSelector.talkTimeShares([
            segment(0, 6, "me"),
            segment(6, 8, "S1"),
            segment(8, 10, "S1"),
            segment(10, 12, nil),
        ])

        XCTAssertEqual(Set(shares.keys), ["me", "S1"])
        XCTAssertEqual(shares.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(shares["me"]), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(shares["S1"]), 0.4, accuracy: 1e-9)
        XCTAssertEqual(SpeakerClipSelector.talkTimeShares([]), [:])
    }
}
