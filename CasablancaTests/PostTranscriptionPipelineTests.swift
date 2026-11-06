import CryptoKit
import SwiftData
import XCTest
@testable import Casablanca

/// The post-recording pipeline used to live inside `TranscriptionView.task`, so
/// navigating away cancelled it and coming back started a second concurrent
/// transcription. These tests pin the two things that move: the pipeline is a
/// value type with injectable steps (so its ORDER is assertable — compression
/// last, after the transcript file and the export), and the run is owned by the
/// service (so a re-trigger is a no-op and Cancel actually stops it).
@MainActor
final class PostTranscriptionPipelineTests: XCTestCase {

    // MARK: - Pipeline order

    func testPipelineOrderIsTranscriptThenCompletedThenExportThenCompress() async throws {
        let context = try makeInMemoryModelContext()
        let wavURL = try makeTemporaryWAV()
        let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        let meeting = Meeting(title: "Sprint Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = wavURL.path
        meeting.status = .processing
        context.insert(meeting)

        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        defaults.set("Casablanca: casa blanca", forKey: AppPreferenceKey.terminologyList)

        let recorder = StepRecorder()
        let pipeline = PostTranscriptionPipeline(
            correctTerminology: { transcript, entries, correction in
                recorder.record("terminology", meeting: meeting)
                XCTAssertEqual(correction, TerminologyCorrectionContext(), "An unlabelled transcript gets the full correction")
                XCTAssertFalse(entries.isEmpty, "The corrector only runs when there are entries to apply")
                XCTAssertEqual(transcript, "[00:00] casa blanca is great")
                return "[00:00] Casablanca is great"
            },
            saveTranscript: { savedMeeting, _ in
                recorder.record("saveTranscript", meeting: savedMeeting)
                return URL(fileURLWithPath: "/tmp/transcript.txt")
            },
            export: { exportedMeeting in
                recorder.record("export", meeting: exportedMeeting)
            },
            compress: { url in
                recorder.record("compress", meeting: meeting)
                XCTAssertEqual(url, wavURL)
                return m4aURL
            },
            defaults: defaults
        )

        await pipeline.run(
            meeting: meeting,
            result: makeResult(text: "casa blanca is great"),
            recordingURL: wavURL,
            modelContext: context
        )

        XCTAssertEqual(
            recorder.steps,
            ["terminology", "saveTranscript", "export", "compress"],
            "Compression is minutes of CPU and nothing downstream needs it, so it must run LAST"
        )
        XCTAssertEqual(
            recorder.statuses,
            [.processing, .completed, .completed, .completed],
            "The meeting must already read as completed before the transcript file, export and compression run"
        )
        XCTAssertEqual(
            recorder.transcripts,
            [nil, "[00:00] Casablanca is great", "[00:00] Casablanca is great", "[00:00] Casablanca is great"],
            "The corrected transcript is on the meeting before anything downstream of it runs"
        )
        XCTAssertEqual(meeting.transcript, "[00:00] Casablanca is great")
        XCTAssertEqual(meeting.rawTranscript, "[00:00] casa blanca is great", "The uncorrected text is kept alongside")
        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.recordingFileURL, m4aURL.path, "A successful compression repoints the meeting")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wavURL.path),
            "The WAV is no longer referenced, so its disk space is reclaimed"
        )
    }

    func testCompressionFailureKeepsWavPath() async throws {
        let context = try makeInMemoryModelContext()
        let wavURL = try makeTemporaryWAV()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let meeting = Meeting(title: "Retro", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = wavURL.path
        meeting.status = .processing
        context.insert(meeting)

        let recorder = StepRecorder()
        let pipeline = PostTranscriptionPipeline(
            correctTerminology: { transcript, _, _ in
                XCTFail("Terminology correction is off, so the corrector must not be called")
                return transcript
            },
            saveTranscript: { savedMeeting, _ in
                recorder.record("saveTranscript", meeting: savedMeeting)
                return URL(fileURLWithPath: "/tmp/transcript.txt")
            },
            export: { exportedMeeting in
                recorder.record("export", meeting: exportedMeeting)
            },
            compress: { _ in
                recorder.record("compress", meeting: meeting)
                throw CocoaError(.fileWriteOutOfSpace)
            },
            defaults: makeDefaults()
        )

        await pipeline.run(
            meeting: meeting,
            result: makeResult(text: "hello"),
            recordingURL: wavURL,
            modelContext: context
        )

        XCTAssertEqual(recorder.steps, ["saveTranscript", "export", "compress"])
        XCTAssertEqual(
            meeting.recordingFileURL,
            wavURL.path,
            "A failed compression must leave the meeting pointing at the WAV"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wavURL.path),
            "The recording is never lost to a failed compression"
        )
        XCTAssertEqual(meeting.transcript, "[00:00] hello", "The transcript survives a failed compression")
        XCTAssertNil(meeting.rawTranscript, "With correction off there is no raw transcript to keep")
        XCTAssertEqual(meeting.status, .completed)
    }

    // MARK: - Speakers

    /// Review focus 4: an old meeting (no tracks) re-transcribes byte-identically,
    /// through the LIVE analyzer, and carries no speaker data.
    func testMeetingWithoutTracksRendersLegacyTranscript() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Old meeting", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = "/tmp/does-not-exist.m4a"
        meeting.speakerSegments = [SpeakerSegment(start: 0, end: 1, speakerID: "me", text: "stale", words: nil)]
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.recogniseSpeakersEnabled)
        let result = TranscriptionResult(
            segments: [
                TranscriptSegment(startTime: 0, endTime: 4, text: "Goedemorgen allemaal."),
                TranscriptSegment(startTime: 65, endTime: 70, text: "Agenda: punt 1"),
                TranscriptSegment(startTime: 3_700, endTime: 3_705, text: "Tot ziens."),
            ],
            fullText: "",
            duration: 3_705
        )

        let pipeline = makePipeline(defaults: defaults, analyzeSpeakers: SpeakerAnalysis.live(defaults: defaults))
        await pipeline.run(meeting: meeting, result: result, recordingURL: URL(fileURLWithPath: "/tmp/x.m4a"), modelContext: context)

        XCTAssertEqual(meeting.transcript, result.formattedTranscript)
        XCTAssertNil(meeting.speakerSegmentsData, "No tracks means no speaker data, and stale data is cleared")
        XCTAssertNil(meeting.speakersData)
        XCTAssertEqual(meeting.status, .completed)
    }

    func testSpeakerSegmentsStoredAndTranscriptHasPrefixes() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(meeting)
        let analysis = Self.twoSpeakerAnalysis(firstText: "Hello there.", secondText: "Hi Youri.")

        var analyzerSawResult: TranscriptionResult?
        let pipeline = makePipeline(defaults: makeDefaults(), analyzeSpeakers: { _, result in
            analyzerSawResult = result
            return .analysed(analysis)
        })
        let result = makeResult(text: "Hello there. Hi Youri.")
        await pipeline.run(meeting: meeting, result: result, recordingURL: URL(fileURLWithPath: "/tmp/x.m4a"), modelContext: context)

        XCTAssertNotNil(analyzerSawResult)
        XCTAssertEqual(meeting.speakers, analysis.speakers)
        XCTAssertEqual(meeting.speakerSegments, analysis.segments)
        XCTAssertEqual(meeting.transcript, "[00:00] Youri: Hello there.\n[00:05] Others: Hi Youri.")
        XCTAssertNil(meeting.rawTranscript, "With correction off there is no raw transcript to keep")
    }

    func testTerminologyAppliedPerSegmentBeforeRender() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        // "Others" is an alias too: a speaker NAME must never be rewritten.
        defaults.set("Casablanca: casa blanca\nAnderen: Others", forKey: AppPreferenceKey.terminologyList)
        let analysis = Self.twoSpeakerAnalysis(firstText: "casa blanca rocks", secondText: "Others agree")

        var corrector: (String, TerminologyCorrectionContext)?
        let pipeline = makePipeline(
            defaults: defaults,
            analyzeSpeakers: { _, _ in .analysed(analysis) },
            correctTerminology: { transcript, _, correction in
                corrector = (transcript, correction)
                return transcript
            }
        )
        await pipeline.run(meeting: meeting, result: makeResult(text: "x"), recordingURL: URL(fileURLWithPath: "/tmp/x.m4a"), modelContext: context)

        XCTAssertEqual(meeting.speakerSegments.map(\.text), ["Casablanca rocks", "Anderen agree"])
        XCTAssertEqual(meeting.rawTranscript, "[00:00] Youri: casa blanca rocks\n[00:05] Others: Others agree",
                       "The raw transcript is the render BEFORE replacement")
        XCTAssertEqual(corrector?.0, "[00:00] Youri: Casablanca rocks\n[00:05] Others: Anderen agree")
        XCTAssertEqual(corrector?.1, TerminologyCorrectionContext(knownSpeakers: ["Youri", "Others"], dictionaryAlreadyApplied: true))
        XCTAssertEqual(meeting.transcript, "[00:00] Youri: Casablanca rocks\n[00:05] Others: Anderen agree")
    }

    /// The deterministic pass is not idempotent when a canonical contains its
    /// own alias ("Team Link: Link"), so the labelled path must run it exactly
    /// once — checked through the REAL TerminologyService.
    func testLabelledPathAppliesDictionaryOnceThroughRealTerminologyService() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        defaults.set("Team Link: Link", forKey: AppPreferenceKey.terminologyList)
        let analysis = Self.twoSpeakerAnalysis(firstText: "link is our team", secondText: "ok")
        let stub = StubLLMProvider(displayName: "Claude Code", supportsFullTranscriptEcho: false)
        let service = TerminologyService(providerFactory: { stub })

        let pipeline = makePipeline(
            defaults: defaults,
            analyzeSpeakers: { _, _ in .analysed(analysis) },
            correctTerminology: PostTranscriptionPipeline.terminologyCorrector(using: service)
        )
        await pipeline.run(meeting: meeting, result: makeResult(text: "x"), recordingURL: URL(fileURLWithPath: "/tmp/x.m4a"), modelContext: context)

        XCTAssertEqual(meeting.transcript, "[00:00] Youri: Team Link is our team\n[00:05] Others: ok")
        XCTAssertEqual(meeting.speakerSegments.first?.text, "Team Link is our team")
    }

    /// The unlabelled path still gets the deterministic pass from the service.
    func testUnlabelledPathStillAppliesDictionaryThroughRealTerminologyService() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        defaults.set("Team Link: Link", forKey: AppPreferenceKey.terminologyList)
        let stub = StubLLMProvider(displayName: "Claude Code", supportsFullTranscriptEcho: false)
        let service = TerminologyService(providerFactory: { stub })

        let pipeline = makePipeline(
            defaults: defaults,
            correctTerminology: PostTranscriptionPipeline.terminologyCorrector(using: service)
        )
        await pipeline.run(meeting: meeting, result: makeResult(text: "link is our team"), recordingURL: URL(fileURLWithPath: "/tmp/x.m4a"), modelContext: context)

        XCTAssertEqual(meeting.transcript, "[00:00] Team Link is our team")
    }

    /// An analysis that failed (nil, e.g. an unreadable track) must not cost
    /// the tracks: a retry can still label the meeting.
    func testKeepSpeakerTracksOffKeepsTracksWhenAnalysisFailed() async throws {
        let context = try makeInMemoryModelContext()
        let files = try makeRecordingWithTracks()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = files.mix.path
        meeting.micTrackFileURL = files.mic.path
        meeting.systemTrackFileURL = files.system.path
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.keepSpeakerTracks)
        defaults.set(true, forKey: AppPreferenceKey.keepOriginalWAV)

        let pipeline = makePipeline(defaults: defaults, analyzeSpeakers: { _, _ in .failed(reason: "track unreadable") })
        await pipeline.run(meeting: meeting, result: makeResult(text: "hi"), recordingURL: files.mix, modelContext: context)

        XCTAssertEqual(meeting.micTrackFileURL, files.mic.path)
        XCTAssertEqual(meeting.systemTrackFileURL, files.system.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.mic.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.system.path))
    }

    /// Recognition off + tracks not kept: nobody asked for the remote voices
    /// to stay on disk, so they go (privacy), even though nothing was analysed.
    /// Goes through the LIVE analyzer so the disabled outcome is the real one.
    func testRecognitionDisabledAndKeepSpeakerTracksOffDeletesTracks() async throws {
        let context = try makeInMemoryModelContext()
        let files = try makeRecordingWithTracks()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = files.mix.path
        meeting.micTrackFileURL = files.mic.path
        meeting.systemTrackFileURL = files.system.path
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.recogniseSpeakersEnabled)
        defaults.set(false, forKey: AppPreferenceKey.keepSpeakerTracks)
        defaults.set(true, forKey: AppPreferenceKey.keepOriginalWAV)

        let pipeline = makePipeline(defaults: defaults, analyzeSpeakers: SpeakerAnalysis.live(defaults: defaults))
        await pipeline.run(meeting: meeting, result: makeResult(text: "hi"), recordingURL: files.mix, modelContext: context)

        XCTAssertNil(meeting.micTrackFileURL)
        XCTAssertNil(meeting.systemTrackFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.mic.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.system.path))
        XCTAssertEqual(meeting.transcript, "[00:00] hi", "Recognition off means the legacy transcript")
    }

    /// The real failure path: the live analyzer cannot read the (fake) tracks,
    /// reports a failure, and the tracks stay for a retry.
    func testUnreadableTracksAreKeptForARetryEvenWhenNotKept() async throws {
        let context = try makeInMemoryModelContext()
        let files = try makeRecordingWithTracks()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = files.mix.path
        meeting.micTrackFileURL = files.mic.path
        meeting.systemTrackFileURL = files.system.path
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.recogniseSpeakersEnabled)
        defaults.set(false, forKey: AppPreferenceKey.keepSpeakerTracks)
        defaults.set(true, forKey: AppPreferenceKey.keepOriginalWAV)

        let pipeline = makePipeline(defaults: defaults, analyzeSpeakers: SpeakerAnalysis.live(defaults: defaults))
        await pipeline.run(meeting: meeting, result: makeResult(text: "hi"), recordingURL: files.mix, modelContext: context)

        XCTAssertEqual(meeting.micTrackFileURL, files.mic.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.mic.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.system.path))
        XCTAssertEqual(meeting.transcript, "[00:00] hi", "A failed analysis still completes, unlabelled")
    }

    func testTracksCompressedAfterMixAndMeetingRepointed() async throws {
        let context = try makeInMemoryModelContext()
        let files = try makeRecordingWithTracks()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = files.mix.path
        meeting.micTrackFileURL = files.mic.path
        meeting.systemTrackFileURL = files.system.path
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.keepSpeakerTracks)

        var compressed: [String] = []
        let pipeline = makePipeline(defaults: defaults, compress: { url in
            compressed.append(url.lastPathComponent)
            let m4a = url.deletingPathExtension().appendingPathExtension("m4a")
            try Data("aac".utf8).write(to: m4a)
            return m4a
        })
        await pipeline.run(meeting: meeting, result: makeResult(text: "hi"), recordingURL: files.mix, modelContext: context)

        XCTAssertEqual(compressed, ["meeting.wav", "meeting.mic.wav", "meeting.system.wav"], "The mix first, then the tracks")
        XCTAssertEqual(meeting.recordingFileURL.map { URL(fileURLWithPath: $0).lastPathComponent }, "meeting.m4a")
        XCTAssertTrue(meeting.micTrackFileURL?.hasSuffix(".mic.m4a") == true)
        XCTAssertTrue(meeting.systemTrackFileURL?.hasSuffix(".system.m4a") == true)
        for wav in [files.mix, files.mic, files.system] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "\(wav.lastPathComponent) is reclaimed")
        }
    }

    func testTrackCompressionFailureKeepsTrackWAV() async throws {
        let context = try makeInMemoryModelContext()
        let files = try makeRecordingWithTracks()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = files.mix.path
        meeting.micTrackFileURL = files.mic.path
        meeting.systemTrackFileURL = files.system.path
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.keepSpeakerTracks)

        let pipeline = makePipeline(defaults: defaults, compress: { url in
            guard !url.lastPathComponent.contains(".mic.") else { throw CocoaError(.fileWriteOutOfSpace) }
            let m4a = url.deletingPathExtension().appendingPathExtension("m4a")
            try Data("aac".utf8).write(to: m4a)
            return m4a
        })
        await pipeline.run(meeting: meeting, result: makeResult(text: "hi"), recordingURL: files.mix, modelContext: context)

        XCTAssertEqual(meeting.micTrackFileURL, files.mic.path, "A failed track compression keeps the WAV")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.mic.path))
        XCTAssertTrue(meeting.systemTrackFileURL?.hasSuffix(".system.m4a") == true)
        XCTAssertEqual(meeting.transcript, "[00:00] hi")
    }

    func testKeepOriginalWAVLeavesTracksAsWAV() async throws {
        let context = try makeInMemoryModelContext()
        let files = try makeRecordingWithTracks()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = files.mix.path
        meeting.micTrackFileURL = files.mic.path
        meeting.systemTrackFileURL = files.system.path
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.keepSpeakerTracks)
        defaults.set(true, forKey: AppPreferenceKey.keepOriginalWAV)

        let pipeline = makePipeline(defaults: defaults, compress: { url in
            XCTFail("Nothing is compressed when the user keeps WAVs: \(url.lastPathComponent)")
            return url
        })
        await pipeline.run(meeting: meeting, result: makeResult(text: "hi"), recordingURL: files.mix, modelContext: context)

        XCTAssertEqual(meeting.micTrackFileURL, files.mic.path)
        XCTAssertEqual(meeting.systemTrackFileURL, files.system.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.mic.path))
    }

    func testKeepSpeakerTracksOffDeletesTracksAfterAnalysis() async throws {
        let context = try makeInMemoryModelContext()
        let files = try makeRecordingWithTracks()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = files.mix.path
        meeting.micTrackFileURL = files.mic.path
        meeting.systemTrackFileURL = files.system.path
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPreferenceKey.keepSpeakerTracks)

        var tracksExistedDuringAnalysis = false
        var compressed: [String] = []
        let pipeline = makePipeline(
            defaults: defaults,
            analyzeSpeakers: { analysedMeeting, _ in
                tracksExistedDuringAnalysis = [analysedMeeting.micTrackFileURL, analysedMeeting.systemTrackFileURL]
                    .allSatisfy { $0.map { FileManager.default.fileExists(atPath: $0) } ?? false }
                return .analysed(Self.twoSpeakerAnalysis(firstText: "a", secondText: "b"))
            },
            compress: { url in
                compressed.append(url.lastPathComponent)
                return url
            }
        )
        await pipeline.run(meeting: meeting, result: makeResult(text: "hi"), recordingURL: files.mix, modelContext: context)

        XCTAssertTrue(tracksExistedDuringAnalysis, "The tracks are deleted only after the analysis read them")
        XCTAssertNil(meeting.micTrackFileURL)
        XCTAssertNil(meeting.systemTrackFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.mic.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.system.path))
        XCTAssertEqual(compressed, ["meeting.wav"], "Tracks about to be deleted are not compressed first")
    }

    // MARK: - Diarization (A5)

    /// Offline: the models cannot download. The meeting still completes, the
    /// far end is `Others`, and the sidecar says diarization failed.
    func testDiarizationFailureStillCompletesWithOthers() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        let fake = FakeSpeakerDiarizer(prepareError: URLError(.notConnectedToInternet))
        let modelStatus = SpeakerModelStatus()
        var statuses: [String] = []

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults,
            diarizer: fake,
            store: fixture.store,
            modelStatus: modelStatus,
            status: { statuses.append($0) }
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertEqual(fixture.meeting.status, .completed)
        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Others: Hello from the far end.")
        guard case .failed = fixture.store.load(fixture.meeting.id)?.diarization else {
            return XCTFail("The record shows the failure, got \(String(describing: fixture.store.load(fixture.meeting.id)))")
        }
        guard case .failed = modelStatus.state else { return XCTFail("Settings shows the failure") }
        XCTAssertEqual(fake.diarizeCalls.count, 0, "No diarization without models")
        XCTAssertEqual(statuses.first, "Recognising speakers\u{2026}")
    }

    func testRecogniseSpeakersOffSkipsDiarizer() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: AppPreferenceKey.recogniseSpeakersEnabled)
        let fake = FakeSpeakerDiarizer()

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults,
            diarizer: fake,
            store: fixture.store,
            modelStatus: SpeakerModelStatus()
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertEqual(fake.totalCalls, 0)
        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Hello from the far end.")
        XCTAssertNil(fixture.store.load(fixture.meeting.id))
    }

    /// Name suggestions (opt-in) never hold up the transcript: the meeting is
    /// stored and `.completed` while the LLM is still thinking, and the
    /// suggestions land in the sidecar afterwards.
    func testTranscriptIsStoredBeforeNameSuggestionsFinish() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000), participants: ["Jan de Vries"])
        context.insert(meeting)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-suggest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpeakerAnalysisStore(directory: directory)
        let defaults = makeDefaults()
        defaults.set(true, forKey: SpeakerPreferenceKey.suggestSpeakerNamesAutomatically)
        let analysis = SpeakerAnalysisResult(
            segments: [SpeakerSegment(start: 0, end: 4, speakerID: "S1", text: "Ik ben Jan.", words: nil)],
            speakers: [SpeakerInfo(id: "S1", displayName: "Speaker 1", source: .system, isUser: false, nameConfirmed: false)],
            diarization: .succeeded(clusterCount: 1)
        )
        let provider = GatedLLMProvider(answer: #"[{"speakerID": "S1", "name": "Jan", "evidence": "Ik ben Jan"}]"#)

        let pipeline = PostTranscriptionPipeline(
            analyzeSpeakers: { meeting, _ in
                try? store.save(SpeakerAnalysisRecord(meetingID: meeting.id, diarization: analysis.diarization, suggestions: []))
                return .analysed(analysis)
            },
            suggestSpeakerNames: SpeakerAnalysis.liveNameSuggester(
                defaults: defaults,
                store: store,
                proposer: SpeakerNameProposer(providerFactory: { provider })
            ),
            correctTerminology: { transcript, _, _ in transcript },
            saveTranscript: { _, _ in URL(fileURLWithPath: "/dev/null") },
            export: { _ in },
            compress: { $0 },
            defaults: defaults
        )
        await pipeline.run(meeting: meeting, result: makeResult(text: "Ik ben Jan."), recordingURL: URL(fileURLWithPath: "/tmp/x.m4a"), modelContext: context)

        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.transcript, "[00:00] Speaker 1: Ik ben Jan.")
        XCTAssertEqual(store.load(meeting.id)?.suggestions, [], "The proposer is still running")

        provider.release()
        let deadline = Date().addingTimeInterval(3)
        while store.load(meeting.id)?.suggestions.isEmpty ?? true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.load(meeting.id)?.suggestions.map(\.name), ["Jan de Vries"])
        XCTAssertEqual(meeting.speakers.first?.displayName, "Speaker 1", "Suggestions are never applied")
        XCTAssertTrue(provider.started)
    }

    func testDiarizedSystemTrackNamesClusters() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        let fake = FakeSpeakerDiarizer(output: DiarizationOutput(
            turns: [DiarizedTurn(start: 0, end: 2, clusterKey: "spk_7")],
            embeddings: ["spk_7": [1, 0]]
        ))
        let modelStatus = SpeakerModelStatus()

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults,
            diarizer: fake,
            store: fixture.store,
            modelStatus: modelStatus
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Speaker 1: Hello from the far end.")
        XCTAssertEqual(fake.diarizeCalls, [fixture.system], "The system track is the one diarized")
        XCTAssertEqual(fixture.store.load(fixture.meeting.id)?.diarization, .succeeded(clusterCount: 1))
        XCTAssertEqual(modelStatus.state, .ready)
    }

    // MARK: - Voice profiles (A7)

    /// A profile store whose one profile ("Kim") matches the fake's cluster.
    private func makeVoiceProfileStore(in directory: URL) throws -> VoiceProfileStore {
        let store = VoiceProfileStore(
            fileURL: directory.appendingPathComponent("VoiceProfiles/profiles.sealed"),
            keyStore: InMemoryKeyStore(),
            isEnabled: { true }
        )
        _ = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true)
        return store
    }

    private let voiceMatchDiarizer = FakeSpeakerDiarizer(output: DiarizationOutput(
        turns: [DiarizedTurn(start: 0, end: 2, clusterKey: "spk_7")],
        embeddings: ["spk_7": [1, 0]]
    ))

    func testVoiceProfilesDisabledNeverMatches() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: AppPreferenceKey.voiceProfilesEnabled)
        let profiles = try makeVoiceProfileStore(in: fixture.directory)

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults, diarizer: voiceMatchDiarizer, store: fixture.store,
            modelStatus: SpeakerModelStatus(), voiceProfiles: profiles
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        let suggestions = try XCTUnwrap(fixture.store.load(fixture.meeting.id)).suggestions
        XCTAssertEqual(suggestions.filter { $0.source == .voiceProfile }.count, 0)
        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Speaker 1: Hello from the far end.")
    }

    /// Enabled: the match is only a suggestion; the speaker keeps its label.
    func testVoiceProfilesEnabledSuggestsWithoutRenaming() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: AppPreferenceKey.voiceProfilesEnabled)
        let profiles = try makeVoiceProfileStore(in: fixture.directory)

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults, diarizer: voiceMatchDiarizer, store: fixture.store,
            modelStatus: SpeakerModelStatus(), voiceProfiles: profiles
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        let suggestions = try XCTUnwrap(fixture.store.load(fixture.meeting.id)).suggestions
        XCTAssertEqual(suggestions.map(\.speakerID), ["S1"])
        XCTAssertEqual(suggestions.map(\.name), ["Kim"])
        XCTAssertEqual(suggestions.map(\.source), [.voiceProfile])
        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Speaker 1: Hello from the far end.", "A match never renames")
        XCTAssertEqual(fixture.meeting.speakers.map(\.nameConfirmed), [false])
    }

    /// The user turns voice profiles off while the speaker step reads the
    /// profiles (here: on the key load). The turn-off purge may already have
    /// run, so the step must not write voice matches back afterwards.
    func testVoiceProfilesTurnedOffMidRunPersistNoVoiceSuggestions() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: AppPreferenceKey.voiceProfilesEnabled)
        let keyStore = HookedKeyStore()
        let profiles = VoiceProfileStore(
            fileURL: fixture.directory.appendingPathComponent("VoiceProfiles/profiles.sealed"),
            keyStore: keyStore,
            isEnabled: { true }
        )
        _ = try profiles.save(name: "Kim", embedding: [1, 0], consentGiven: true)
        // UserDefaults is thread-safe; the hook runs on the store's background read.
        nonisolated(unsafe) let defaults = fixture.defaults
        keyStore.setOnLoad { defaults.set(false, forKey: AppPreferenceKey.voiceProfilesEnabled) }

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults, diarizer: voiceMatchDiarizer, store: fixture.store,
            modelStatus: SpeakerModelStatus(), voiceProfiles: profiles
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertFalse(fixture.defaults.bool(forKey: AppPreferenceKey.voiceProfilesEnabled), "The hook ran mid-run")
        let suggestions = try XCTUnwrap(fixture.store.load(fixture.meeting.id)).suggestions
        XCTAssertEqual(suggestions.filter { $0.source == .voiceProfile }, [])
    }

    func testRecognisingStatusIsReplacedWhenDiarizationEnds() async throws {
        for fake in [
            FakeSpeakerDiarizer(output: DiarizationOutput(turns: [DiarizedTurn(start: 0, end: 2, clusterKey: "a")], embeddings: [:])),
            FakeSpeakerDiarizer(diarizeError: CocoaError(.fileReadCorruptFile)),
        ] {
            let fixture = try makeDiarizationFixture()
            defer { fixture.cleanUp() }
            var statuses: [String] = []
            let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
                defaults: fixture.defaults, diarizer: fake, store: fixture.store,
                modelStatus: SpeakerModelStatus(), status: { statuses.append($0) }
            ))
            await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

            XCTAssertEqual(statuses.first, "Recognising speakers\u{2026}")
            XCTAssertEqual(statuses.count, 2, "The recognising line is replaced, got \(statuses)")
            XCTAssertNotEqual(statuses.last, "Recognising speakers\u{2026}")
        }
    }

    /// keepSpeakerTracks OFF + a transient failure (offline): the tracks stay
    /// so a retry can still diarize.
    func testTransientDiarizationFailureKeepsTracksWhenNotKept() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: AppPreferenceKey.keepSpeakerTracks)
        let fake = FakeSpeakerDiarizer(prepareError: URLError(.notConnectedToInternet))

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults, diarizer: fake, store: fixture.store, modelStatus: SpeakerModelStatus()
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertEqual(fixture.meeting.micTrackFileURL, fixture.mic.path)
        XCTAssertEqual(fixture.meeting.systemTrackFileURL, fixture.system.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mic.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.system.path))
    }

    /// keepSpeakerTracks OFF on a Mac where diarization can never run: nothing
    /// to retry, so the tracks go — and no per-meeting status lines.
    func testUnsupportedOSDeletesTracksWhenNotKeptAndShowsNoStatus() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: AppPreferenceKey.keepSpeakerTracks)
        let fake = FakeSpeakerDiarizer(isAvailable: false)
        let modelStatus = SpeakerModelStatus()
        var statuses: [String] = []

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults, diarizer: fake, store: fixture.store,
            modelStatus: modelStatus, status: { statuses.append($0) }
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertEqual(fake.totalCalls, 0)
        XCTAssertEqual(statuses, [])
        XCTAssertEqual(modelStatus.state, .notDownloaded)
        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Others: Hello from the far end.")
        guard case .unsupported = fixture.store.load(fixture.meeting.id)?.diarization else {
            return XCTFail("The record says unsupported")
        }
        XCTAssertNil(fixture.meeting.micTrackFileURL)
        XCTAssertNil(fixture.meeting.systemTrackFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mic.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.system.path))
    }

    /// Pins that A2 attributes a mic-only (in-room) meeting, so the in-room
    /// diarization is reachable: the MIC track is diarized, every speaker is a
    /// room speaker, and a mic word no turn claims is not labelled the user.
    func testMicOnlyMeetingIsDiarizedIntoRoomSpeakers() async throws {
        let fixture = try makeDiarizationFixture(micOnly: true)
        defer { fixture.cleanUp() }
        let fake = FakeSpeakerDiarizer(output: DiarizationOutput(
            turns: [DiarizedTurn(start: 0, end: 2, clusterKey: "x"), DiarizedTurn(start: 2, end: 4, clusterKey: "y")],
            embeddings: [:]
        ))
        fixture.defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults, diarizer: fake, store: fixture.store, modelStatus: SpeakerModelStatus()
        ))
        let result = TranscriptionResult(
            segments: [
                TranscriptSegment(startTime: 0, endTime: 2, text: "Welcome."),
                TranscriptSegment(startTime: 2, endTime: 4, text: "Thanks."),
                TranscriptSegment(startTime: 8, endTime: 9, text: "Later."),
            ],
            fullText: "",
            duration: 9
        )
        await pipeline.run(meeting: fixture.meeting, result: result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertEqual(fake.diarizeCalls, [fixture.mic])
        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Speaker 1: Welcome.\n[00:02] Speaker 2: Thanks.\n[00:08] Speaker 2: Later.")
        XCTAssertEqual(fixture.meeting.speakers.map(\.source), [.room, .room])
        XCTAssertEqual(fixture.meeting.speakers.map(\.isUser), [false, false])
    }

    func testTimeoutCancelsTheDiarizationRun() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        let fake = FakeSpeakerDiarizer(delay: 5)

        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults, diarizer: fake, store: fixture.store,
            modelStatus: SpeakerModelStatus(), diarizationTimeout: .milliseconds(100)
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        let deadline = ContinuousClock.now + .seconds(2)
        while !fake.wasCancelled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(fake.wasCancelled, "The timed-out run is cancelled, so it cannot overlap the next meeting")
    }

    func testDiarizationTimeoutFallsBackToOthers() async throws {
        let fixture = try makeDiarizationFixture()
        defer { fixture.cleanUp() }
        let fake = FakeSpeakerDiarizer(
            output: DiarizationOutput(turns: [DiarizedTurn(start: 0, end: 2, clusterKey: "late")], embeddings: [:]),
            delay: 5
        )

        let started = ContinuousClock.now
        let pipeline = makePipeline(defaults: fixture.defaults, analyzeSpeakers: SpeakerAnalysis.live(
            defaults: fixture.defaults,
            diarizer: fake,
            store: fixture.store,
            modelStatus: SpeakerModelStatus(),
            diarizationTimeout: .milliseconds(100)
        ))
        await pipeline.run(meeting: fixture.meeting, result: fixture.result, recordingURL: fixture.mix, modelContext: fixture.context)

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(4), "The timeout does not wait for the diarizer")
        XCTAssertEqual(fixture.meeting.transcript, "[00:00] Others: Hello from the far end.")
        guard case .failed = fixture.store.load(fixture.meeting.id)?.diarization else {
            return XCTFail("A timeout is recorded as a failure")
        }
    }

    private struct DiarizationFixture {
        var context: ModelContext
        var meeting: Meeting
        var defaults: UserDefaults
        var store: SpeakerAnalysisStore
        var result: TranscriptionResult
        var directory: URL
        var mix: URL
        var mic: URL
        var system: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Two seconds of synthetic noise on the system track and silence on the
    /// mic, so the live attribution puts the one segment on `"others"`.
    private func makeDiarizationFixture(micOnly: Bool = false) throws -> DiarizationFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-diarization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mix = directory.appendingPathComponent("meeting.wav")
        let mic = directory.appendingPathComponent("meeting.mic.wav")
        let system = directory.appendingPathComponent("meeting.system.wav")
        if micOnly {
            // In-room: everyone on the mic for 10 s, no system track.
            let room = SyntheticSignal.noise(seed: 13, count: SyntheticSignal.samples(10), amplitude: 0.4)
            try SyntheticSignal.writeWAV(room, to: mic)
            try SyntheticSignal.writeWAV(room, to: mix)
        } else {
            let far = SyntheticSignal.noise(seed: 11, count: SyntheticSignal.samples(2), amplitude: 0.4)
            try SyntheticSignal.writeWAV(far, to: system)
            try SyntheticSignal.writeWAV(SyntheticSignal.silence(seconds: 2), to: mic)
            try SyntheticSignal.writeWAV(far, to: mix)
        }

        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Call", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = mix.path
        meeting.micTrackFileURL = mic.path
        meeting.systemTrackFileURL = micOnly ? nil : system.path
        meeting.transcriptionLanguage = "en"
        context.insert(meeting)
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPreferenceKey.recogniseSpeakersEnabled)
        defaults.set(true, forKey: AppPreferenceKey.keepSpeakerTracks)
        defaults.set(true, forKey: AppPreferenceKey.keepOriginalWAV)

        return DiarizationFixture(
            context: context,
            meeting: meeting,
            defaults: defaults,
            store: SpeakerAnalysisStore(directory: directory.appendingPathComponent("Speakers", isDirectory: true)),
            result: TranscriptionResult(
                segments: [TranscriptSegment(startTime: 0, endTime: 2, text: "Hello from the far end.")],
                fullText: "Hello from the far end.",
                duration: 2
            ),
            directory: directory,
            mix: mix,
            mic: mic,
            system: system
        )
    }

    /// A segment each for the user and the remote side, at 0 s and 5 s.
    private static func twoSpeakerAnalysis(firstText: String, secondText: String) -> SpeakerAnalysisResult {
        SpeakerAnalysisResult(
            segments: [
                SpeakerSegment(start: 0, end: 4, speakerID: SpeakerIDs.me, text: firstText, words: nil),
                SpeakerSegment(start: 5, end: 7, speakerID: SpeakerIDs.others, text: secondText, words: nil),
            ],
            speakers: [
                SpeakerInfo(id: SpeakerIDs.me, displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
                SpeakerInfo(id: SpeakerIDs.others, displayName: "Others", source: .system, isUser: false, nameConfirmed: false),
            ],
            diarization: .notRun
        )
    }

    private func makePipeline(
        defaults: UserDefaults,
        analyzeSpeakers: @escaping PostTranscriptionPipeline.SpeakerAnalyzer = { _, _ in .skipped },
        correctTerminology: @escaping PostTranscriptionPipeline.TerminologyCorrector = { transcript, _, _ in transcript },
        compress: @escaping PostTranscriptionPipeline.Compressor = { url in url }
    ) -> PostTranscriptionPipeline {
        PostTranscriptionPipeline(
            analyzeSpeakers: analyzeSpeakers,
            correctTerminology: correctTerminology,
            saveTranscript: { _, _ in URL(fileURLWithPath: "/dev/null") },
            export: { _ in },
            compress: compress,
            defaults: defaults
        )
    }

    private func makeRecordingWithTracks() throws -> (directory: URL, mix: URL, mic: URL, system: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-tracks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mix = directory.appendingPathComponent("meeting.wav")
        let mic = directory.appendingPathComponent("meeting.mic.wav")
        let system = directory.appendingPathComponent("meeting.system.wav")
        for url in [mix, mic, system] {
            try Data("not really audio".utf8).write(to: url)
        }
        return (directory, mix, mic, system)
    }

    // MARK: - Service-owned background run

    /// `transcribeInBackground` can reach neither a real WhisperKit nor the live
    /// pipeline in a test, so both are driven through the service's DEBUG seams:
    /// the live pipeline reads `UserDefaults.standard`, writes into the real
    /// Application Support, exports into the user's real Obsidian vault and can
    /// make a billed LLM terminology call. Everything under test here — the
    /// guards, the wind-down wait, the cancel path — is production code.
    func testSecondBackgroundRunForSameMeetingIsNoOp() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = makeMeeting(titled: "Standup", in: context)
        let service = makeService()
        let pipelineRuns = EventLog()
        service.pipelineOverrideForTesting = makeFakePipeline(log: pipelineRuns)

        let runs = Counter()
        service.transcribeOverrideForTesting = { _, _ in
            runs.increment()
            return makeResult(text: "hello")
        }

        start(service, meeting, context)
        XCTAssertEqual(service.transcribingMeetingID, meeting.id)

        // The re-trigger a re-appearing view produces: it must not start a second
        // concurrent transcription on the same WhisperKit instance.
        start(service, meeting, context)

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(runs.value, 1, "A second run for the meeting already transcribing is ignored")
        XCTAssertEqual(pipelineRuns.events, ["pipeline"], "…and the pipeline runs once, not twice")
        XCTAssertNil(service.transcribingMeetingID, "The run clears itself on the way out")
        XCTAssertEqual(service.lastCompletedMeetingID, meeting.id, "A clean run reports the meeting it finished")
        XCTAssertNil(service.lastError, "A no-op re-trigger is not an error: that run is genuinely showing")
    }

    /// The refusal that would otherwise be invisible. Callers flip the meeting to
    /// `.processing` *before* calling (NotesEditorView after Stop, ContentView's
    /// "Transcribe"), so a silent refusal leaves it spinning on a run that does
    /// not exist, with `.task` unable to re-fire and Cancel disabled.
    func testRejectedRunForAnotherMeetingSurfacesAnError() async throws {
        let context = try makeInMemoryModelContext()
        let running = makeMeeting(titled: "Sprint Review", in: context)
        let refused = makeMeeting(titled: "Retro", in: context)
        let service = makeService()
        service.pipelineOverrideForTesting = makeFakePipeline(log: EventLog())

        let runs = Counter()
        let gate = Gate()
        service.transcribeOverrideForTesting = { _, _ in
            runs.increment()
            await gate.wait()
            return makeResult(text: "hello")
        }

        start(service, running, context)
        start(service, refused, context)

        XCTAssertEqual(service.transcribingMeetingID, running.id, "The live run keeps the service")
        guard case .anotherTranscriptionInProgress(let blockingTitle) = service.lastError else {
            return XCTFail("A refused start must surface an error, got \(String(describing: service.lastError))")
        }
        XCTAssertEqual(blockingTitle, "Sprint Review", "The error names what is blocking the start")
        XCTAssertEqual(
            service.lastError?.localizedDescription,
            "Another meeting (Sprint Review) is still being transcribed. Try again when it finishes.",
            "The alert has to read as an instruction, not as a failure"
        )

        gate.open()
        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(runs.value, 1, "The refused meeting never started a decode of its own")
        XCTAssertEqual(
            service.lastCompletedMeetingID,
            running.id,
            "Only the run that was already going completes"
        )
    }

    /// Retry straight after Cancel. `cancel()` leaves `transcribingMeetingID` set
    /// until the old task unwinds, so a re-trigger in that window used to be
    /// refused — leaving the meeting stuck. It now waits the predecessor out and
    /// then runs, which also keeps the two decodes off one WhisperKit instance.
    func testRestartAfterCancelWaitsForWindDownThenRuns() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = makeMeeting(titled: "Bilateral", in: context)
        let service = makeService()
        let log = EventLog()
        service.pipelineOverrideForTesting = makeFakePipeline(log: log)

        let decodes = Counter()
        service.transcribeOverrideForTesting = { _, _ in
            decodes.increment()
            let decode = decodes.value
            log.append("decode \(decode) started")
            if decode == 1 {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    log.append("decode 1 unwound")
                    throw error
                }
            }
            log.append("decode \(decode) finished")
            return makeResult(text: "hello")
        }

        start(service, meeting, context)
        service.cancel()
        // The window the fix is about: cancelled, but not yet unwound.
        start(service, meeting, context)

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(
            log.events,
            ["decode 1 started", "decode 1 unwound", "decode 2 started", "decode 2 finished", "pipeline"],
            "The replacement run starts only after the cancelled one has unwound"
        )
        XCTAssertEqual(decodes.value, 2, "The restart really ran; it was not swallowed as a duplicate")
        XCTAssertEqual(service.lastCompletedMeetingID, meeting.id)
        XCTAssertNil(service.transcribingMeetingID)
        XCTAssertNil(service.lastError, "Neither the cancel nor the restart is a failure")
    }

    func testCancelStopsBackgroundTask() async throws {
        let context = try makeInMemoryModelContext()
        let meeting = makeMeeting(titled: "Week start", in: context)
        let service = makeService()
        let pipelineRuns = EventLog()
        service.pipelineOverrideForTesting = makeFakePipeline(log: pipelineRuns)

        let started = Counter()
        let gate = Gate()
        let cancellationReachedTheDecode = Flag()
        service.transcribeOverrideForTesting = { _, _ in
            started.increment()
            // Stands in for a long transcription: it waits, and on release
            // reports whether the cancellation reached this far IN — proving the
            // inner step is cancelled, not just the task wrapping it.
            await gate.wait()
            cancellationReachedTheDecode.set(Task.isCancelled)
            try Task.checkCancellation()
            XCTFail("A cancelled run must not reach its result")
            return makeResult(text: "unreachable")
        }

        start(service, meeting, context)
        service.cancel()
        gate.open()

        await service.waitForBackgroundWorkForTesting()

        XCTAssertEqual(started.value, 1)
        XCTAssertTrue(
            cancellationReachedTheDecode.value,
            "Cancellation has to propagate INTO the transcription step, not stop at the task boundary"
        )
        XCTAssertEqual(pipelineRuns.events, [], "A cancelled run never reaches the pipeline")
        XCTAssertNil(service.transcribingMeetingID, "Cancel ends the service-owned run")
        XCTAssertNil(service.lastCompletedMeetingID, "A cancelled run never completes the pipeline")
        XCTAssertNil(service.lastError, "Cancel is user intent, not a failure to surface")
        XCTAssertNil(meeting.transcript, "A cancelled run writes no transcript")
    }

    // MARK: - Helpers

    private func makeService() -> TranscriptionService {
        TranscriptionService(
            sleepPreventer: FakeSleepPreventer(),
            memoryPressureMonitor: FakeMemoryPressureMonitor()
        )
    }

    private func makeMeeting(titled title: String, in context: ModelContext) -> Meeting {
        let meeting = Meeting(title: title, date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.recordingFileURL = "/tmp/does-not-matter.wav"
        context.insert(meeting)
        return meeting
    }

    /// A pipeline whose every step is a fake reading scratch preferences, so no
    /// service-level test can touch `UserDefaults.standard`, the real
    /// Application Support, the user's Obsidian vault, or an LLM. Appends
    /// "pipeline" to `log` from the transcript-saving step, which always runs, so
    /// a test can tell whether the pipeline was reached at all.
    private func makeFakePipeline(log: EventLog) -> PostTranscriptionPipeline {
        PostTranscriptionPipeline(
            correctTerminology: { transcript, _, _ in transcript },
            saveTranscript: { _, _ in
                log.append("pipeline")
                return URL(fileURLWithPath: "/dev/null")
            },
            export: { _ in },
            compress: { url in url },
            defaults: makeDefaults()
        )
    }

    /// Starts a background run with the fakes the tests share.
    private func start(_ service: TranscriptionService, _ meeting: Meeting, _ context: ModelContext) {
        service.transcribeInBackground(
            meeting: meeting,
            modelContext: context,
            terminologyService: TerminologyService(),
            exportReporter: nil
        )
    }

    private func makeInMemoryModelContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "post-transcription-\(UUID().uuidString)")!
    }

    private func makeTemporaryWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casablanca-pipeline-\(UUID().uuidString).wav")
        try Data("not really audio".utf8).write(to: url)
        return url
    }
}

/// One transcript segment's worth of result, enough for `formattedTranscript`.
private func makeResult(text: String) -> TranscriptionResult {
    TranscriptionResult(
        segments: [TranscriptSegment(startTime: 0, endTime: 1, text: text)],
        fullText: text,
        duration: 1
    )
}

/// Records the pipeline steps in the order they run, together with the meeting
/// state visible at each one — the order alone would not prove that the meeting
/// reads as completed before the export and the compression.
@MainActor
private final class StepRecorder {
    private(set) var steps: [String] = []
    private(set) var statuses: [MeetingStatus] = []
    private(set) var transcripts: [String?] = []

    func record(_ step: String, meeting: Meeting) {
        steps.append(step)
        statuses.append(meeting.status)
        transcripts.append(meeting.transcript)
    }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// An ordered list of what happened, for the assertions that are about order.
@MainActor
private final class EventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

@MainActor
private final class Flag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}

/// Holds a fake transcription open until the test releases it, so "while a run
/// is in flight" is a fact rather than a race.
private actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func openNow() {
        isOpen = true
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}

extension Gate {
    /// Callable from the main-actor tests without an await ceremony at each site.
    nonisolated func open() {
        Task { await self.openNow() }
    }
}

private final class FakeSleepPreventer: SleepPreventing {
    func begin(reason: String) -> SleepPreventionToken {
        SleepPreventionToken {}
    }
}

private final class FakeMemoryPressureMonitor: MemoryPressureMonitoring {
    func start(handler: @escaping @Sendable () -> Void) {}
}

/// A provider that answers only once `release()` is called, standing in for a
/// slow LLM.
private final class GatedLLMProvider: LLMProvider, @unchecked Sendable {
    let displayName = "Gated"
    let endpoint = "stub://gated"
    let preferredTimeout: TimeInterval? = nil
    let supportsFullTranscriptEcho = true
    let promptTokenBudget = LLMPromptSupport.localPromptTokenBudget

    private let answer: String
    private let lock = NSLock()
    private var isReleased = false
    private var didStart = false

    init(answer: String) { self.answer = answer }

    var started: Bool { lock.withLock { didStart } }
    func release() { lock.withLock { isReleased = true } }

    func generate(
        prompt: String,
        temperature: Double?,
        maxTokens: Int?,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String {
        lock.withLock { didStart = true }
        while !lock.withLock({ isReleased }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        return answer
    }

    func fetchAvailableModels(endpoint: String) async throws -> [String] { [] }
}

/// A key store that runs a hook on every key load, to act "while the
/// profiles are being read".
private final class HookedKeyStore: SymmetricKeyStoring, @unchecked Sendable {
    private let base = InMemoryKeyStore()
    private let lock = NSLock()
    private var onLoad: (@Sendable () -> Void)?

    func setOnLoad(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { onLoad = hook }
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        lock.withLock { onLoad }?()
        return try base.loadOrCreateKey()
    }

    func deleteKey() throws {
        try base.deleteKey()
    }
}
