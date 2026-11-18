import XCTest
@testable import Casablanca

@MainActor
final class SpeakerNameProposerTests: XCTestCase {

    private let speakers = [
        SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
        SpeakerInfo(id: "S1", displayName: "Speaker 1", source: .system, isUser: false, nameConfirmed: false),
        SpeakerInfo(id: "S2", displayName: "Speaker 2", source: .system, isUser: false, nameConfirmed: false),
        SpeakerInfo(id: "S3", displayName: "Kim", source: .system, isUser: false, nameConfirmed: true),
    ]

    private let participants = ["Jan de Vries", "Kim Owen-Jones", "Youri Broekhuizen"]

    private let transcript = """
    [00:00] Youri: Goedemorgen allemaal, Jan, wil jij beginnen?
    [00:04] Speaker 1: Ja hoor. Ik ben Jan en ik   doe de   integraties.
    [00:12] Speaker 2: En ik ben Priya van het architectuurteam.
    [09:59] Kim: Laatste punt voor de tien minuten.
    [10:01] Speaker 2: Dit staat na tien minuten en hoort niet in de prompt.
    """

    // MARK: - Prompt

    func testPromptIncludesParticipantsAndOnlyFirstTenMinutes() {
        let prompt = SpeakerNameProposer.prompt(speakers: speakers, participants: participants, transcript: transcript)

        for participant in participants {
            XCTAssertTrue(prompt.contains(participant), "Missing participant \(participant)")
        }
        XCTAssertTrue(prompt.contains("[00:04] Speaker 1: Ja hoor."))
        XCTAssertTrue(prompt.contains("[09:59] Kim: Laatste punt"))
        XCTAssertFalse(prompt.contains("[10:01]"))
        XCTAssertFalse(prompt.contains("hoort niet in de prompt"))
        XCTAssertTrue(prompt.contains(#"[{"speakerID": "...", "name": "...|null", "evidence": "verbatim quote"}]"#))
    }

    func testPromptExcludesUserAndConfirmedSpeakers() {
        let prompt = SpeakerNameProposer.prompt(speakers: speakers, participants: participants, transcript: transcript)
        let speakerSection = prompt.components(separatedBy: "Participants").first ?? prompt

        XCTAssertTrue(prompt.contains("S1: Speaker 1"))
        XCTAssertTrue(prompt.contains("S2: Speaker 2"))
        XCTAssertFalse(prompt.contains("me: Youri"))
        XCTAssertFalse(prompt.contains("S3: Kim"))
        XCTAssertFalse(speakerSection.contains("me:"))
    }

    func testPromptIsCappedInLength() {
        let long = (0..<2000).map { "[00:\(String(format: "%02d", $0 % 60))] Speaker 1: \(String(repeating: "woord ", count: 10))" }
            .joined(separator: "\n")
        let prompt = SpeakerNameProposer.prompt(speakers: speakers, participants: participants, transcript: long)
        XCTAssertLessThanOrEqual(prompt.count, SpeakerNameProposer.maxPromptCharacters + 2_000)
    }

    // MARK: - Parse

    func testParsesFencedJSONWithEvidence() {
        let response = """
        Here you go:
        ```json
        [
          {"speakerID": "S1", "name": "Jan", "evidence": "Ik ben Jan en ik doe de integraties"},
          {"speakerID": "S2", "name": "Priya", "evidence": "ik ben Priya van het architectuurteam"}
        ]
        ```
        """

        let suggestions = SpeakerNameProposer.parse(response, speakers: speakers, participants: participants, transcript: transcript)

        XCTAssertEqual(suggestions, [
            SpeakerNameSuggestion(
                speakerID: "S1",
                name: "Jan de Vries",
                evidence: "Ik ben Jan en ik doe de integraties",
                source: .transcript,
                score: nil
            ),
            SpeakerNameSuggestion(
                speakerID: "S2",
                name: "Priya",
                evidence: "ik ben Priya van het architectuurteam",
                source: .transcript,
                score: nil
            ),
        ])
    }

    func testParsesBareArray() {
        let response = #"[{"speakerID": "S1", "name": "jan de vries", "evidence": "Ik ben Jan"}]"#
        let suggestions = SpeakerNameProposer.parse(response, speakers: speakers, participants: participants, transcript: transcript)
        XCTAssertEqual(suggestions.map(\.name), ["Jan de Vries"])
    }

    func testDropsEvidenceNotInTranscript() {
        let response = """
        [{"speakerID": "S1", "name": "Jan", "evidence": "Ik ben Jan, de baas van iedereen"},
         {"speakerID": "S2", "name": "Priya", "evidence": ""}]
        """
        XCTAssertEqual(
            SpeakerNameProposer.parse(response, speakers: speakers, participants: participants, transcript: transcript),
            []
        )
    }

    func testDropsNameNotInParticipantsOrTranscript() {
        let response = """
        [{"speakerID": "S1", "name": "Pieter", "evidence": "Ik ben Jan"},
         {"speakerID": "S2", "name": "Speaker 1", "evidence": "En ik ben Priya"}]
        """
        XCTAssertEqual(
            SpeakerNameProposer.parse(response, speakers: speakers, participants: participants, transcript: transcript),
            []
        )
    }

    func testDropsUnknownUserAndConfirmedSpeakers() {
        let response = """
        [{"speakerID": "me", "name": "Jan", "evidence": "Ik ben Jan"},
         {"speakerID": "S3", "name": "Jan", "evidence": "Ik ben Jan"},
         {"speakerID": "S9", "name": "Jan", "evidence": "Ik ben Jan"}]
        """
        XCTAssertEqual(
            SpeakerNameProposer.parse(response, speakers: speakers, participants: participants, transcript: transcript),
            []
        )
    }

    func testNullNameDropped() {
        let response = #"[{"speakerID": "S1", "name": null, "evidence": "Ik ben Jan"}]"#
        XCTAssertEqual(
            SpeakerNameProposer.parse(response, speakers: speakers, participants: participants, transcript: transcript),
            []
        )
    }

    func testMalformedJSONGivesNoSuggestions() {
        for response in ["", "no idea", "[{\"speakerID\": \"S1\", \"name\": ", "{\"speakerID\": \"S1\"}", "```json\n[1, 2]\n```"] {
            XCTAssertEqual(
                SpeakerNameProposer.parse(response, speakers: speakers, participants: participants, transcript: transcript),
                [],
                "Response: \(response)"
            )
        }
    }

    // MARK: - Propose

    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000), participants: participants)
        meeting.transcript = transcript
        meeting.speakers = speakers
        return meeting
    }

    func testProposeDoesNotMutateMeeting() async {
        let meeting = makeMeeting()
        let stub = StubLLMProvider(outcomes: [
            .success(#"[{"speakerID": "S1", "name": "Jan", "evidence": "Ik ben Jan"}]"#),
        ])
        let proposer = SpeakerNameProposer(providerFactory: { stub })

        let suggestions = await proposer.propose(for: meeting)

        XCTAssertEqual(suggestions.map(\.speakerID), ["S1"])
        XCTAssertEqual(meeting.speakers, speakers)
        XCTAssertEqual(meeting.transcript, transcript)
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testProposeFailureGivesNoSuggestionsWithoutRetry() async {
        let stub = StubLLMProvider(outcomes: [.failure(StubLLMProvider.transientFailure())])
        let proposer = SpeakerNameProposer(providerFactory: { stub })

        let suggestions = await proposer.propose(for: makeMeeting())

        XCTAssertEqual(suggestions, [])
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testProposeSkipsTheLLMWithoutCandidates() async {
        let meeting = makeMeeting()
        meeting.speakers = speakers.filter { $0.isUser || $0.nameConfirmed }
        let stub = StubLLMProvider()

        let suggestions = await SpeakerNameProposer(providerFactory: { stub }).propose(for: meeting)

        XCTAssertEqual(suggestions, [])
        XCTAssertEqual(stub.calls.count, 0)
    }

    // MARK: - Automatic (opt-in, non-blocking) and manual suggestions

    private func makeStore() -> (SpeakerAnalysisStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNameProposerTests-\(UUID().uuidString)", isDirectory: true)
        return (SpeakerAnalysisStore(directory: directory), directory)
    }

    private func makeDefaults(autoSuggest: Bool?) -> UserDefaults {
        let suite = "SpeakerNameProposerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let autoSuggest {
            defaults.set(autoSuggest, forKey: AppPreferenceKey.suggestSpeakerNamesAutomatically)
        }
        return defaults
    }

    private let janAnswer = #"[{"speakerID": "S1", "name": "Jan", "evidence": "Ik ben Jan"}]"#

    func testAutomaticSuggestionsAreOffByDefault() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = makeMeeting()
        try store.save(SpeakerAnalysisRecord(meetingID: meeting.id, diarization: .succeeded(clusterCount: 2), suggestions: []))
        let stub = StubLLMProvider(outcomes: [.success(janAnswer)])
        let suggester = SpeakerAnalysis.liveNameSuggester(
            defaults: makeDefaults(autoSuggest: nil),
            store: store,
            proposer: SpeakerNameProposer(providerFactory: { stub })
        )

        XCTAssertNil(suggester(meeting), "No automatic LLM call without the opt-in")
        XCTAssertEqual(stub.calls.count, 0)
    }

    func testAutomaticSuggestionsWriteTheSidecarWhenEnabled() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = makeMeeting()
        try store.save(SpeakerAnalysisRecord(meetingID: meeting.id, diarization: .succeeded(clusterCount: 2), suggestions: []))
        let stub = StubLLMProvider(outcomes: [.success(janAnswer)])
        let suggester = SpeakerAnalysis.liveNameSuggester(
            defaults: makeDefaults(autoSuggest: true),
            store: store,
            proposer: SpeakerNameProposer(providerFactory: { stub })
        )

        let task = try XCTUnwrap(suggester(meeting))
        await task.value

        XCTAssertEqual(store.load(meeting.id)?.suggestions.map(\.name), ["Jan de Vries"])
        XCTAssertEqual(store.load(meeting.id)?.diarization, .succeeded(clusterCount: 2), "The record keeps its outcome")
        XCTAssertEqual(meeting.speakers, speakers, "Suggestions never touch the meeting")
        XCTAssertTrue(stub.calls.first?.prompt.contains("[00:04] Speaker 1: Ja hoor.") ?? false)
    }

    func testAutomaticSuggestionsNeedASucceededDiarizationAndUnnamedSpeakers() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = StubLLMProvider(outcomes: [.success(janAnswer)])
        let suggester = SpeakerAnalysis.liveNameSuggester(
            defaults: makeDefaults(autoSuggest: true),
            store: store,
            proposer: SpeakerNameProposer(providerFactory: { stub })
        )

        let failed = makeMeeting()
        try store.save(SpeakerAnalysisRecord(meetingID: failed.id, diarization: .failed(reason: "offline"), suggestions: []))
        XCTAssertNil(suggester(failed))

        let noRecord = makeMeeting()
        XCTAssertNil(suggester(noRecord))

        let named = makeMeeting()
        named.speakers = speakers.map { var s = $0; s.nameConfirmed = true; return s }
        try store.save(SpeakerAnalysisRecord(meetingID: named.id, diarization: .succeeded(clusterCount: 2), suggestions: []))
        XCTAssertNil(suggester(named))

        XCTAssertEqual(stub.calls.count, 0)
    }

    func testAutomaticSuggestionFailureLeavesTheSidecarAlone() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = makeMeeting()
        let record = SpeakerAnalysisRecord(meetingID: meeting.id, diarization: .succeeded(clusterCount: 2), suggestions: [])
        try store.save(record)
        let stub = StubLLMProvider(outcomes: [.failure(StubLLMProvider.transientFailure())])
        let suggester = SpeakerAnalysis.liveNameSuggester(
            defaults: makeDefaults(autoSuggest: true),
            store: store,
            proposer: SpeakerNameProposer(providerFactory: { stub })
        )

        await suggester(meeting)?.value

        XCTAssertEqual(store.load(meeting.id), record)
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testManualSuggestRunsEvenWhenTheSettingIsOff() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = makeMeeting()
        let stub = StubLLMProvider(outcomes: [.success(janAnswer)])

        // No sidecar yet (an older meeting): the manual path creates one.
        let suggestions = await SpeakerAnalysis.suggestNamesNow(
            for: meeting,
            store: store,
            proposer: SpeakerNameProposer(providerFactory: { stub })
        )

        XCTAssertEqual(suggestions.map(\.speakerID), ["S1"])
        XCTAssertEqual(store.load(meeting.id)?.suggestions, suggestions)
        XCTAssertEqual(store.load(meeting.id)?.diarization, .notRun)
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(meeting.speakers, speakers)
    }

    /// Transcript suggestions replace earlier transcript suggestions only:
    /// voice-profile matches (A7) stay in the sidecar.
    func testTranscriptSuggestionsKeepVoiceProfileSuggestions() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = makeMeeting()
        let voice = SpeakerNameSuggestion(speakerID: "S2", name: "Kim", evidence: "Voice profile match", source: .voiceProfile, score: 0.9)
        let stale = SpeakerNameSuggestion(speakerID: "S2", name: "Old", evidence: "earlier", source: .transcript, score: nil)
        try store.save(SpeakerAnalysisRecord(meetingID: meeting.id, diarization: .succeeded(clusterCount: 2), suggestions: [voice, stale]))
        let stub = StubLLMProvider(outcomes: [.success(janAnswer)])

        let suggestions = await SpeakerAnalysis.suggestNamesNow(
            for: meeting,
            store: store,
            proposer: SpeakerNameProposer(providerFactory: { stub })
        )

        XCTAssertEqual(store.load(meeting.id)?.suggestions, [voice] + suggestions)
    }

    func testStoreSaveAnnouncesTheChangedRecord() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let announced = expectation(forNotification: SpeakerAnalysisStore.recordDidChange, object: nil) { note in
            note.userInfo?[SpeakerAnalysisStore.meetingIDKey] as? UUID == id
        }
        try store.save(SpeakerAnalysisRecord(meetingID: id, diarization: .notRun, suggestions: []))
        wait(for: [announced], timeout: 1)
    }
}
