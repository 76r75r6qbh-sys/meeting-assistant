import XCTest
@testable import Casablanca

final class SpeakerTranscriptBuilderTests: XCTestCase {

    func testUserNameFromFirstAlias() {
        let speakers = SpeakerTranscriptBuilder.speakers(
            for: [segment("me")],
            language: "en-US",
            userAliases: ["Youri", "YB"],
            hasSystemTrack: true,
            roomClusters: false
        )

        XCTAssertEqual(speakers, [
            SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
        ])
    }

    func testFallbackMeAndIkByLanguage() {
        let english = SpeakerTranscriptBuilder.speakers(
            for: [segment("me")], language: "en-US", userAliases: [], hasSystemTrack: false, roomClusters: false
        )
        let dutch = SpeakerTranscriptBuilder.speakers(
            for: [segment("me")], language: "nl-NL", userAliases: [], hasSystemTrack: false, roomClusters: false
        )

        XCTAssertEqual(english.first?.displayName, "Me")
        XCTAssertEqual(dutch.first?.displayName, "Ik")
        XCTAssertEqual(english.first?.isUser, true)
        XCTAssertEqual(english.first?.source, .microphone)
        XCTAssertEqual(english.first?.nameConfirmed, false, "A fallback label is not a confirmed name")
    }

    func testOthersLabelByLanguage() {
        let english = SpeakerTranscriptBuilder.speakers(
            for: [segment("others")], language: "en", userAliases: ["Youri"], hasSystemTrack: true, roomClusters: false
        )
        let dutch = SpeakerTranscriptBuilder.speakers(
            for: [segment("others")], language: "nl", userAliases: ["Youri"], hasSystemTrack: true, roomClusters: false
        )

        XCTAssertEqual(english, [
            SpeakerInfo(id: "others", displayName: "Others", source: .system, isUser: false, nameConfirmed: false),
        ])
        XCTAssertEqual(dutch.first?.displayName, "Anderen")
        XCTAssertEqual(dutch.first?.source, .system)
        XCTAssertEqual(dutch.first?.nameConfirmed, false)
    }

    func testSpeakersInOrderOfFirstAppearanceWithoutDuplicatesOrNil() {
        let speakers = SpeakerTranscriptBuilder.speakers(
            for: [segment(nil), segment("others"), segment("me"), segment("others"), segment("S2"), segment("S1")],
            language: "nl-NL",
            userAliases: ["Youri"],
            hasSystemTrack: true,
            roomClusters: false
        )

        XCTAssertEqual(speakers.map(\.id), ["others", "me", "S2", "S1"])
        XCTAssertEqual(speakers.map(\.displayName), ["Anderen", "Youri", "Spreker 2", "Spreker 1"])
        XCTAssertEqual(speakers[2].source, .system)
    }

    func testRoomClustersUseRoomSource() {
        let speakers = SpeakerTranscriptBuilder.speakers(
            for: [segment("S1")], language: "en", userAliases: [], hasSystemTrack: false, roomClusters: true
        )
        XCTAssertEqual(speakers, [
            SpeakerInfo(id: "S1", displayName: "Speaker 1", source: .room, isUser: false, nameConfirmed: false),
        ])
    }

    func testAliasIsSanitizedForThePrefix() {
        let speakers = SpeakerTranscriptBuilder.speakers(
            for: [segment("me")], language: "en", userAliases: ["  Youri: [B]  "], hasSystemTrack: false, roomClusters: false
        )
        XCTAssertEqual(speakers.first?.displayName, "Youri B")
    }

    private func segment(_ speakerID: String?) -> SpeakerSegment {
        SpeakerSegment(start: 0, end: 1, speakerID: speakerID, text: "x", words: nil)
    }
}
