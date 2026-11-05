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

    // MARK: - Diarization (A5)

    func testSystemWordsGetClusterByMaxOverlap() {
        // "b" overlaps spk_a by 0.2 s and spk_b by 0.6 s.
        let input = [wordSegment("others", words: [("one", 0, 1), ("two", 1.0, 1.8)])]
        let turns = [
            DiarizedTurn(start: 0, end: 1.2, clusterKey: "spk_a"),
            DiarizedTurn(start: 1.2, end: 3, clusterKey: "spk_b"),
        ]

        let out = SpeakerTranscriptBuilder.assignClusters(input, turns: turns, targetSpeakerID: "others")

        XCTAssertEqual(out.segments.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(out.segments.map(\.text), ["one", "two"])
        XCTAssertEqual(out.clusterOrder, ["spk_a", "spk_b"])
    }

    func testNearestTurnWithinHalfSecond() {
        // The word ends 0.4 s before spk_x starts and 0.9 s after spk_y ends.
        let input = [wordSegment("others", words: [("hi", 2.0, 2.6)])]
        let turns = [
            DiarizedTurn(start: 0, end: 1.1, clusterKey: "spk_y"),
            DiarizedTurn(start: 3.0, end: 5, clusterKey: "spk_x"),
        ]

        let out = SpeakerTranscriptBuilder.assignClusters(input, turns: turns, targetSpeakerID: "others")

        XCTAssertEqual(out.segments.map(\.speakerID), ["S1"])
        XCTAssertEqual(out.clusterOrder, ["spk_x"])
    }

    func testWordFarFromAnyTurnStaysOthers() {
        let input = [wordSegment("others", words: [("far", 10, 11)])]
        let turns = [DiarizedTurn(start: 0, end: 9.4, clusterKey: "spk_1")]

        let out = SpeakerTranscriptBuilder.assignClusters(input, turns: turns, targetSpeakerID: "others")

        XCTAssertEqual(out.segments.map(\.speakerID), ["others"])
        XCTAssertEqual(out.clusterOrder, [])
    }

    func testClusterIDsNumberedByFirstAppearance() {
        let input = [
            wordSegment("others", words: [("first", 0, 2)]),
            wordSegment("others", words: [("second", 3, 5)]),
            wordSegment("others", words: [("third", 6, 8)]),
        ]
        let turns = [
            DiarizedTurn(start: 0, end: 2, clusterKey: "spk_3"),
            DiarizedTurn(start: 3, end: 5, clusterKey: "spk_1"),
            DiarizedTurn(start: 6, end: 8, clusterKey: "spk_3"),
        ]

        let out = SpeakerTranscriptBuilder.assignClusters(input, turns: turns, targetSpeakerID: "others")

        XCTAssertEqual(out.segments.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertEqual(out.clusterOrder, ["spk_3", "spk_1"])
    }

    func testShortClusterRunIsAbsorbed() {
        // A 0.3 s blip of spk_b inside spk_a speech is not a speaker change.
        let input = [wordSegment("others", words: [("a", 0, 1), ("b", 1, 1.3), ("c", 1.3, 2.5)])]
        let turns = [
            DiarizedTurn(start: 0, end: 1, clusterKey: "spk_a"),
            DiarizedTurn(start: 1, end: 1.3, clusterKey: "spk_b"),
            DiarizedTurn(start: 1.3, end: 2.5, clusterKey: "spk_a"),
        ]

        let out = SpeakerTranscriptBuilder.assignClusters(input, turns: turns, targetSpeakerID: "others")

        XCTAssertEqual(out.segments.count, 1)
        XCTAssertEqual(out.segments.first?.speakerID, "S1")
        XCTAssertEqual(out.clusterOrder, ["spk_a"])
    }

    func testMicWordsNeverGetClusters() {
        let input = [
            wordSegment("me", words: [("mine", 0, 2)]),
            wordSegment("others", words: [("theirs", 2, 4)]),
        ]
        let turns = [DiarizedTurn(start: 0, end: 4, clusterKey: "spk_0")]

        let out = SpeakerTranscriptBuilder.assignClusters(input, turns: turns, targetSpeakerID: "others")

        XCTAssertEqual(out.segments.map(\.speakerID), ["me", "S1"])
        XCTAssertEqual(out.segments[0], input[0], "A mic segment comes back unchanged")
    }

    func testDutchClusterLabelsUseSpreker() {
        let base = SpeakerAnalysisResult(
            segments: [
                wordSegment("me", words: [("ik", 0, 1)]),
                wordSegment("others", words: [("jij", 1, 2)]),
                wordSegment("others", words: [("zij", 3, 4)]),
            ],
            speakers: [],
            diarization: .notRun
        )
        let turns = [
            DiarizedTurn(start: 1, end: 2, clusterKey: "a"),
            DiarizedTurn(start: 3, end: 4, clusterKey: "b"),
        ]

        let result = SpeakerTranscriptBuilder.diarizedResult(
            base, turns: turns, hasSystemTrack: true, language: "nl-NL", userAliases: ["Youri"]
        )

        XCTAssertEqual(result.speakers, [
            SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
            SpeakerInfo(id: "S1", displayName: "Spreker 1", source: .system, isUser: false, nameConfirmed: false),
            SpeakerInfo(id: "S2", displayName: "Spreker 2", source: .system, isUser: false, nameConfirmed: false),
        ])
        XCTAssertEqual(result.diarization, .succeeded(clusterCount: 2))
        XCTAssertEqual(
            TranscriptLineFormat.render(result.segments, speakers: result.speakers),
            "[00:00] Youri: ik\n[00:01] Spreker 1: jij\n[00:03] Spreker 2: zij"
        )
    }

    func testMicOnlyWithTwoRoomClustersProducesRoomSpeakers() {
        let base = SpeakerAnalysisResult(
            segments: [
                wordSegment("me", words: [("hello", 0, 2)]),
                wordSegment("me", words: [("hi", 2, 4)]),
            ],
            speakers: [SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true)],
            diarization: .notRun
        )
        let turns = [
            DiarizedTurn(start: 0, end: 2, clusterKey: "x"),
            DiarizedTurn(start: 2, end: 4, clusterKey: "y"),
        ]

        let result = SpeakerTranscriptBuilder.diarizedResult(
            base, turns: turns, hasSystemTrack: false, language: "en", userAliases: ["Youri"]
        )

        XCTAssertEqual(result.segments.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(result.speakers, [
            SpeakerInfo(id: "S1", displayName: "Speaker 1", source: .room, isUser: false, nameConfirmed: false),
            SpeakerInfo(id: "S2", displayName: "Speaker 2", source: .room, isUser: false, nameConfirmed: false),
        ])
        XCTAssertEqual(result.diarization, .succeeded(clusterCount: 2))
    }

    func testMicOnlyWithOneClusterLabelsUserOnly() {
        let base = SpeakerAnalysisResult(
            segments: [wordSegment("me", words: [("hello", 0, 2)]), wordSegment("me", words: [("again", 2, 4)])],
            speakers: [SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true)],
            diarization: .notRun
        )
        let turns = [DiarizedTurn(start: 0, end: 4, clusterKey: "only")]

        let result = SpeakerTranscriptBuilder.diarizedResult(
            base, turns: turns, hasSystemTrack: false, language: "en", userAliases: ["Youri"]
        )

        XCTAssertEqual(result.segments, base.segments)
        XCTAssertEqual(result.speakers, base.speakers)
        XCTAssertEqual(result.diarization, .succeeded(clusterCount: 1))
    }

    private func wordSegment(_ speakerID: String, words: [(String, Double, Double)]) -> SpeakerSegment {
        let transcriptWords = words.map { TranscriptWord(start: $0.1, end: $0.2, text: " " + $0.0) }
        return SpeakerSegment(
            start: words.first?.1 ?? 0,
            end: words.last?.2 ?? 0,
            speakerID: speakerID,
            text: words.map(\.0).joined(separator: " "),
            words: transcriptWords
        )
    }

    private func segment(_ speakerID: String?) -> SpeakerSegment {
        SpeakerSegment(start: 0, end: 1, speakerID: speakerID, text: "x", words: nil)
    }
}
