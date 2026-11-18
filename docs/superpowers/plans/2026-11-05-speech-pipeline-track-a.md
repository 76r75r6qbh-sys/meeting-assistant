# Speech pipeline Track A (audio and speakers): implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every transcript line says who spoke. The per-source tracks are kept, words are attributed to mic or system by energy (with a bleed guard), the system track is diarized offline with FluidAudio, and speakers can be named (with LLM suggestions the user confirms). Voiceprints are optional and encrypted.

**Architecture:** Recording keeps the per-segment mic/system PCM. At Stop it merges each track into a WAV that is sample-aligned with the mix. Transcription still runs once, on the mix, now with word timestamps and terminology prompt tokens. A new `Services/Speakers/` layer then runs in `PostTranscriptionPipeline` before terminology. It reads per-track RMS envelopes, attributes each word, maps system words onto FluidAudio clusters and builds `[SpeakerSegment]` + `[SpeakerInfo]` (Phase 0 types). Those are rendered through `TranscriptLineFormat`. Everything after diarization (suggestions, voice matches) goes into a per-meeting sidecar JSON, so no schema change is needed beyond Phase 0's V3.

**Tech Stack:** Swift 5 / SwiftUI / SwiftData (macOS 14), AVFoundation, WhisperKit (pinned `d447d308`), FluidAudio (new SPM dep, Apache-2.0), CryptoKit + Security (Keychain).

**Spec:** `docs/superpowers/specs/2026-11-05-speech-pipeline-best-practices-design.md`, section "Track A — Audio and speakers" plus "Contracts shared by all tracks" (binding). Master plan: `docs/superpowers/plans/2026-11-05-speech-pipeline-best-practices.md`.

## Global Constraints

- Work in worktree `../lahore-track-a` on branch `76r75r6qbh-sys/speech-pipeline-track-a`, branched from the Phase 0 tip. Never push, never open a PR, never release.
- Targeted tests only, never the full suite. Every "Run:" below means this exact command, with the `-only-testing:` flags listed in the step appended:
  `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test-track-a -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
  Expected PASS output: `** TEST SUCCEEDED **`.
- Consume the Phase 0 interfaces exactly and do not redefine them: `SpeakerSegment`, `TranscriptWord`, `SpeakerInfo`, `SpeakerSource` (`.microphone/.system/.room`), `SpeakerData`, `TranscriptLineFormat` (`render`, `renameSpeaker`, `parse(_:knownSpeakers:)`, `timestampLabel`), `Meeting.speakerSegments/speakers/speakerSegmentsData/speakersData/micTrackFileURL/systemTrackFileURL`, `AudioClipPlayer.shared.play(url:from:duration:)`, and `AppPreferenceKey.recogniseSpeakersEnabled` (true) / `keepSpeakerTracks` (true) / `wordTimestampsEnabled` (true) / `voiceProfilesEnabled` (false).
- Never edit `Meeting.swift`, `TodoItem.swift`, `CasablancaSchema.swift`, `SettingsView.swift`, `Models/SpeakerTranscript.swift`, `Models/ExtractedActionItem.swift`, `Services/TranscriptLineFormat.swift` or `Services/AudioClipPlayer.swift`. Anything those need goes in the task's **Phase 2 handoff** note.
- Every new file needs PBXFileReference, PBXBuildFile, group and Sources-phase entries in `Casablanca.xcodeproj/project.pbxproj`. Copy `SummarizationService.swift` for app files and `StubLLMProvider.swift` for test files. Create the group `Casablanca/Services/Speakers` in Task A2 if Phase 0 did not. Keep pbxproj edits minimal.
- Transcript line contract: `[mm:ss] <Speaker>: <text>`. The prefix is optional. A meeting without tracks must render byte-identically to today's `TranscriptionResult.formattedTranscript`.
- Speaker IDs (Track A owns them, `SpeakerIDs` in Task A2): the user is `"me"`, the undiarized system track is `"others"`, and diarized clusters are `"S1"`, `"S2"`… numbered by first appearance in time. The user's display name is the first entry of `AppPreferences.userNameAliases()`, falling back to `Me` (en) or `Ik` (nl). Clusters are `Speaker N` / `Spreker N`. The undiarized system track is `Others` / `Anderen`. The language is nl when `meeting.transcriptionLanguage` has the prefix `nl`.
- Never call a live LLM, the network, FluidAudio models or WhisperKit models in tests. Use `StubLLMProvider` and the fake diarizer from Task A5.
- Owners and names are never applied silently. Voiceprints are off by default and need per-person consent.
- Captured audio is never destroyed by the track work. A track-merge failure logs and continues; it never fails the Stop or the transcript.
- Commits: conventional messages ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Mic-only recording** (system capture failed, or the lid was closed) leaves no system track file. The pipeline completes and labels only the user. Pinned by `RecordingTrackMergerTests.testMicOnlySessionWritesNoSystemTrack` (A1) and `SpeakerTranscriptBuilderTests.testMicOnlyWithOneClusterLabelsUserOnly` (A5).
2. **Diarization model download fails offline or FluidAudio throws.** The transcript still completes, system speech is labelled `Others`, and the reason is recorded. Pinned by `PostTranscriptionPipelineTests.testDiarizationFailureStillCompletesWithOthers` (A5).
3. **Paused/resumed meeting with uneven track lengths per segment, plus a crash-recovered segment.** Track sample positions equal the mix's positions. Pinned by `RecordingTrackMergerTests.testPadsEachSegmentToMixLengthAcrossPauses` and `RecordingSessionRecoveryTests.testRecoveredSegmentKeepsTrackPCMForTheMerge` (A1).
4. **Re-transcribing an old meeting** (no tracks) gives a transcript byte-identical to before. A meeting whose tracks are already m4a still attributes. Pinned by `PostTranscriptionPipelineTests.testMeetingWithoutTracksRendersLegacyTranscript` (A2) and `TrackEnergyEnvelopeTests.testReadsCompressedM4ATrack` (A2).
5. **Rename onto an existing name, or after hand edits.** Same-name speakers merge and only prefixes change. Pinned by `SpeakerRenamerTests.testRenameToExistingNameMergesSpeakers` and `testRenamePreservesHandEditedText` (A6).

---

### Task A1: Keep per-source tracks (point 1)

**Files:**
- Modify: `Casablanca/Services/Recording/RecordingMixdownRenderer.swift:126-131` (keep instead of delete)
- Modify: `Casablanca/Services/Recording/RecordingFiles.swift` (kept-track naming)
- Modify: `Casablanca/Services/Recording/RecordingTypes.swift` (`RecordingResult`)
- Create: `Casablanca/Services/Recording/RecordingTrackMerger.swift`
- Modify: `Casablanca/Services/Recording/AudioRecordingService.swift:66-80, 359-367` (inject + call merger before `deleteSession`)
- Modify: `Casablanca/Services/Recording/MeetingRecordingController.swift:146-148` (store track paths)
- Modify: `Casablanca/ViewModels/MeetingListViewModel.swift:334-344` (delete track files with the recording)
- Test: `CasablancaTests/RecordingMixdownTests.swift` (rewrite the two delete tests), `CasablancaTests/RecordingSessionRecoveryTests.swift` (add), `CasablancaTests/RecordingTrackMergerTests.swift` (new), `CasablancaTests/AudioRecordingServiceTrackMergeTests.swift` (new), `CasablancaTests/MeetingListViewModelTrackDeletionTests.swift` (new)

**Interfaces:**
- Consumes: `Meeting.micTrackFileURL`, `Meeting.systemTrackFileURL` (Phase 0), `WAVCodec.header(dataByteCount:)`, `WAVCodec.headerByteCount`.
- Produces:
  - `RecordingFiles.keptTrackURL(for pcmURL: URL) -> URL`: `segment-007.mic.pcm` becomes `segment-007.mic.kept.pcm`. The `.kept.pcm` suffix deliberately does not end in `.mic.pcm`/`.system.pcm`, so recovery's inventory never re-renders or reports it as stranded, while `hasRecoverableAudio` still counts it (extension `pcm`).
  - `RecordingFiles.speakerTrackURL(forRecording: URL, kind: RecordingTrackKind) -> URL`: `<name>.wav` becomes `<name>.mic.wav` or `<name>.system.wav`. `RecordingCompressor.compress` then yields `<name>.mic.m4a` / `<name>.system.m4a` unchanged.
  - `struct SpeakerTrackFiles: Equatable { var microphone: URL?; var system: URL? }`.
  - `enum RecordingTrackMerger { static func merge(segmentWAVs: [URL], recordingURL: URL, chunkFrames: Int = 65_536) throws -> SpeakerTrackFiles; static func mergeInBackground(segmentWAVs: [URL], recordingURL: URL) async -> SpeakerTrackFiles /* never throws: logs, removes partials, returns empty */; static func int16Samples(fromFloat: [Float]) -> [Int16] /* unity gain, clamp ±1, × Int16.max, rounded */ }`.
  - `RecordingResult` gains `var microphoneTrackURL: URL? = nil`, `var systemTrackURL: URL? = nil`.
  - `AudioRecordingService.init(… mergeTracks: @escaping ([URL], URL) async -> SpeakerTrackFiles = RecordingTrackMerger.mergeInBackground …)`.

Alignment rule (decided here): for each segment WAV in manifest-index order (the same `segmentURLs` array `stopRecording` passes to `mergeSegments`), the authoritative frame count is `mixFrames = (wavBytes − 44) / 2`. Each track writes `min(trackFrames, mixFrames)` converted samples, then zero-pads to `mixFrames`. A missing kept file is all zeros. So both tracks are exactly as long as the merged mix, and sample *n* of a track is sample *n* of the mix. A track whose kept PCM totals 0 bytes over all segments is not written (`nil`).

- [ ] **Step 1: Write the failing tests**
  - `RecordingMixdownTests.testSuccessfulRenderKeepsBothTracksUnderKeptNames` replaces `testSuccessfulRenderRemovesBothFullyReadTracks`. After `render()`, `mic.pcm`/`system.pcm` are gone, `keptTrackURL(for:)` of each exists, and their bytes equal the input bytes.
  - `RecordingMixdownTests.testUncountedTrackWithSamplesIsKept` keeps its current assertions. `system` (fewer than 4 bytes) is still deleted, not kept.
  - `RecordingSessionRecoveryTests.testRecoveredSegmentKeepsTrackPCMForTheMerge`: `renderSegment` on an orphaned pair leaves `segment-001.mic.kept.pcm` + `.system.kept.pcm`.
  - `RecordingSessionRecoveryTests.testScanDoesNotReportKeptTrackPCMAsStranded`: a directory with a manifest WAV and kept PCMs scans as `.resumable(_, segmentCount: 1, strandedPCM: [])`.
  - `RecordingTrackMergerTests.testPadsEachSegmentToMixLengthAcrossPauses`: segment 1 has mic 3 frames and system 5; segment 2 has mic 4 and system 0, with WAVs of 5 and 4 frames. Expect mic.wav to have 9 frames `[m1,m2,m3,0,0,n1…n4]` and system.wav 9 frames `[s1…s5,0,0,0,0]`. Both data byte counts equal the merged mix's.
  - `RecordingTrackMergerTests.testMissingKeptFileForASegmentIsSilence` covers an adopted legacy WAV without kept PCM.
  - `RecordingTrackMergerTests.testTrackLongerThanMixIsTruncated`.
  - `RecordingTrackMergerTests.testMicOnlySessionWritesNoSystemTrack`: `result.system == nil` and no `.system.wav` on disk.
  - `RecordingTrackMergerTests.testFloatConversionClampsAndRounds`: `[1.5, -1.5, 0.5]` becomes `[32767, -32767, 16384]`.
  - `RecordingTrackMergerTests.testFailedMergeLeavesNoPartialAndReturnsEmpty`: an unreadable kept file leads to `mergeInBackground` returning `SpeakerTrackFiles()` and leaving no `.partial` files.
  - `AudioRecordingServiceTrackMergeTests.testStopMergesTracksBeforeDeletingSession`: the fake `mergeTracks` asserts the session directory still exists when it is called. The result carries its URLs.
  - `AudioRecordingServiceTrackMergeTests.testTrackMergeFailureDoesNotFailStop`.
  - `MeetingListViewModelTrackDeletionTests.testDeleteMeetingRemovesTrackFiles`: the injected `removeItemAtURL` records the recording, mic and system paths. A missing track file does not throw.
- [ ] **Step 2: Run to verify failure.** Run: `-only-testing:CasablancaTests/RecordingMixdownTests -only-testing:CasablancaTests/RecordingSessionRecoveryTests -only-testing:CasablancaTests/RecordingTrackMergerTests -only-testing:CasablancaTests/AudioRecordingServiceTrackMergeTests -only-testing:CasablancaTests/MeetingListViewModelTrackDeletionTests`. Expected: build failure (`RecordingTrackMerger` and `keptTrackURL` undefined).
- [ ] **Step 3: Implement.**
  - Renderer: where it deletes today, `moveItem` to `keptTrackURL` (replace an existing kept file). If the move fails, delete as before and log; the mix holds the audio.
  - `RecordingSessionRecovery.renderSegment` needs no edit, because it goes through the renderer.
  - Merger: stream with the partial-file-then-move pattern of `RecordingSegmentMerger.merge`.
  - `stopRecording`: `let tracks = await mergeTracks(segmentURLs, finalURL)` after `mergeSegments` and before `sessionStore.deleteSession`, then return them in `RecordingResult`.
  - The controller sets `meeting.micTrackFileURL` / `systemTrackFileURL` from the result.
  - `deleteMeeting` removes both track paths with the same missing-file tolerance as the recording.
- [ ] **Step 4: Run the tests from Step 2, plus `-only-testing:CasablancaTests/RecordingSegmentMergerTests -only-testing:CasablancaTests/RecordingResumeAndStopContractTests -only-testing:CasablancaTests/RecordingSessionTeardownResilienceTests`.** Expected: `** TEST SUCCEEDED **` (mix golden pins unchanged).
- [ ] **Step 5: Commit** `feat(recording): keep per-source speaker tracks aligned with the mix`.

**Phase 2 handoff:** none.

---

### Task A2: Energy attribution and bleed guard (points 1, 2)

**Files:**
- Create: `Casablanca/Services/Speakers/TrackEnergyEnvelope.swift`, `Casablanca/Services/Speakers/SpeakerAttribution.swift`, `Casablanca/Services/Speakers/SpeakerTranscriptBuilder.swift`, `Casablanca/Services/Speakers/SpeakerAnalysis.swift`
- Modify: `Casablanca/Services/Transcription/PostTranscriptionPipeline.swift` (speaker step before terminology; track compression/deletion step after the mix compression)
- Modify: `Casablanca/Services/TerminologyService.swift` (additive: prefix-preserving check)
- Test: `CasablancaTests/TrackEnergyEnvelopeTests.swift`, `CasablancaTests/SpeakerAttributionTests.swift`, `CasablancaTests/SpeakerTranscriptBuilderTests.swift` (new), `CasablancaTests/PostTranscriptionPipelineTests.swift`, `CasablancaTests/TerminologyServiceTests.swift` (add)

**Interfaces:**
- Consumes: A1 track URLs on `Meeting`, the Phase 0 types, `TerminologyService.dictionaryReplace`, and `TranscriptSegment.words` (added in A3; until then `nil`, so A2 also works segment-level).
- Produces:
  - `enum SpeakerIDs { static let me = "me"; static let others = "others"; static func cluster(_ ordinal: Int) -> String /* "S\(ordinal)" */ }`
  - `struct EnergyEnvelope: Equatable { static let frameDuration = 0.05; var rms: [Float] /* one value per 50 ms frame, 800 samples at 16 kHz */; func meanSquare(from: Double, to: Double) -> Float }` and `enum TrackEnergyEnvelope { static func read(url: URL) throws -> EnergyEnvelope /* AVAudioFile + AVAudioConverter to 16 kHz mono float, streamed in chunks; reads WAV and m4a */; static func envelope(samples: [Float]) -> EnergyEnvelope }`
  - `enum AttributedSource: Equatable { case microphone, system, undetermined }`
  - `struct SpeakerAttribution { struct Thresholds: Equatable { var micGain: Float = 1.35; var systemGain: Float = 0.8; var silenceFloorRMS: Float = 0.004; var micShareForMic: Float = 0.65; var micShareForSystem: Float = 0.35; var bleedCorrelation: Float = 0.80; var bleedMaxLagFrames = 4; var bleedMinWindow = 0.6; var minRunDuration = 0.6; static let `default` = Thresholds() }; init(mic: EnergyEnvelope?, system: EnergyEnvelope?, thresholds: Thresholds = .default); func source(from: Double, to: Double) -> AttributedSource; func attribute(_ segments: [TranscriptSegment]) -> [SpeakerSegment] /* speakerID .me / .others, split on source runs ≥ minRunDuration */ }`
  - `struct SpeakerAnalysisResult: Equatable { var segments: [SpeakerSegment]; var speakers: [SpeakerInfo]; var diarization: DiarizationOutcome }` and `enum DiarizationOutcome: Codable, Equatable { case notRun, disabled, succeeded(clusterCount: Int), failed(reason: String) }` (the `DiarizationOutcome` cases are used from A5 on).
  - `enum SpeakerTranscriptBuilder { static func speakers(for segments: [SpeakerSegment], language: String, userAliases: [String], hasSystemTrack: Bool, roomClusters: Bool) -> [SpeakerInfo] }`
  - `PostTranscriptionPipeline` gains an injected `typealias SpeakerAnalyzer = @MainActor (Meeting, TranscriptionResult) async -> SpeakerAnalysisResult?` (`live` = `SpeakerAnalysis.live(defaults:)`) and `typealias TrackCompressor = Compressor`.
  - `TerminologyService.correct(_:entries:knownSpeakers: Set<String>) async -> String` overload. It rejects the LLM output (and returns the deterministic text with a warning) when `speakerPrefixesPreserved(input:output:knownSpeakers:) == false`.
  - `nonisolated static func speakerPrefixesPreserved(input: String, output: String, knownSpeakers: Set<String>) -> Bool`: the per-line sequence of known prefixes (via `TranscriptLineFormat.parse(_:knownSpeakers:)`) must be identical.

Algorithm decisions (starting values pinned by `testDefaultThresholdsArePinned`):
- **Per frame:** `m = rms_mic × micGain`, `s = rms_sys × systemGain`. These are the mix gains, so the ratio describes contribution to what Whisper heard.
- **Source of a span:** sum `m²` and `s²` over the frames of `[start, end]`.
  - Both RMS below `silenceFloorRMS`: `.undetermined`.
  - Bleed guard: when the system mean RMS is above the floor, compute the Pearson correlation of the mic and system envelopes over the span, padded symmetrically to at least `bleedMinWindow`, at mic lags `0…bleedMaxLagFrames` (0–200 ms; the mic hears the speakers late). If the maximum is `≥ bleedCorrelation`, the span is `.system` whatever the energy ratio.
  - Otherwise `micShare = Σm² / (Σm² + Σs²)`: `.microphone` at `≥ 0.65`, `.system` at `≤ 0.35`, else `.undetermined`.
- **Words:** each word gets a source, and `.undetermined` inherits the previous word's source (the first word inherits the next determined one; all undetermined means the segment is `.microphone` when there is no system envelope, else `.system`). Then runs shorter than `minRunDuration` (word start to end) are absorbed into the preceding run (the following run at segment start), and the segment is split at each remaining change. A split segment's `start`/`end` come from its first and last word, and its text is its words joined by `""` with Whisper's leading spaces trimmed.
- **No words:** the whole segment uses `source(from:to:)`. A segment that is entirely `.undetermined` follows the rule above.
- **No mic and no system envelope** (old meeting): `attribute` returns the segments with `speakerID = nil` and words carried over.

- [ ] **Step 1: Write the failing tests.** Synthetic signals come from a seeded LCG (`SyntheticSignal.noise(seed:count:amplitude:)` in the test file), 16 kHz, built in memory. Envelopes go through `TrackEnergyEnvelope.envelope(samples:)`.
  - `TrackEnergyEnvelopeTests.testFrameRMSOfConstantSignal`: a constant 0.5 signal over 1 s gives 20 frames, each 0.5 ± 1e-6.
  - `TrackEnergyEnvelopeTests.testReadsWAVMatchesInMemoryEnvelope`.
  - `TrackEnergyEnvelopeTests.testReadsCompressedM4ATrack`: compress a fixture WAV via `RecordingCompressor.compress`. The envelope frame count equals the WAV's ±1 frame, and the mean RMS is within 10 %.
  - `SpeakerAttributionTests.testDefaultThresholdsArePinned`: asserts every value listed in the Interfaces block.
  - `SpeakerAttributionTests.testUserAloneIsMic`: mic is a 0.3 noise burst over 2 s, system is silent, so `.microphone`.
  - `SpeakerAttributionTests.testRemoteAloneIsSystem`.
  - `SpeakerAttributionTests.testRemoteVoiceLeakingIntoMicIsAttributedToSystem`: system is modulated noise (4 Hz on/off), and mic is `0.9 × system` delayed 100 ms plus noise at amplitude 0.001. The mic share exceeds 0.65, yet the result is `.system`.
  - `SpeakerAttributionTests.testDoubleTalkUncorrelatedStaysMic`: independent seeds, mic louder, so `.microphone`.
  - `SpeakerAttributionTests.testSilenceIsUndetermined`.
  - `SpeakerAttributionTests.testUndeterminedWordInheritsPreviousSource`.
  - `SpeakerAttributionTests.testShortFlipUnder0_6sIsAbsorbed`: a 0.4 s system blip inside a mic segment gives 1 output segment with `speakerID "me"`.
  - `SpeakerAttributionTests.testSourceChangeOver0_6sSplitsSegment`: 2 output segments (`"me"` then `"others"`). Starts and ends equal the boundary words', and all words are preserved in order.
  - `SpeakerAttributionTests.testSegmentWithoutWordsUsesSegmentLevelAttribution`.
  - `SpeakerAttributionTests.testMicOnlyMeetingAttributesEverythingToMic`: `system: nil`.
  - `SpeakerAttributionTests.testNoEnvelopesLeavesSpeakerNil`.
  - `SpeakerAttributionTests.testDeterministic`: the same input twice gives equal output.
  - `SpeakerTranscriptBuilderTests.testUserNameFromFirstAlias`: aliases `["Youri","YB"]` give a `"me"` display name `Youri`, `isUser` true, `nameConfirmed` true, source `.microphone`.
  - `SpeakerTranscriptBuilderTests.testFallbackMeAndIkByLanguage`.
  - `SpeakerTranscriptBuilderTests.testOthersLabelByLanguage`: `Others` / `Anderen`, source `.system`, `nameConfirmed` false.
  - `PostTranscriptionPipelineTests.testMeetingWithoutTracksRendersLegacyTranscript`: `meeting.transcript == result.formattedTranscript`.
  - `PostTranscriptionPipelineTests.testSpeakerSegmentsStoredAndTranscriptHasPrefixes`: a fake analyzer is set up so that `meeting.speakers` and `meeting.speakerSegments` are set, and the lines read `[00:00] Youri: …` / `[00:05] Others: …`.
  - `PostTranscriptionPipelineTests.testTerminologyAppliedPerSegmentBeforeRender`: the segment text holds the canonical term.
  - `PostTranscriptionPipelineTests.testTracksCompressedAfterMixAndMeetingRepointed`: URLs end in `.mic.m4a` / `.system.m4a` and the WAVs are deleted.
  - `PostTranscriptionPipelineTests.testKeepSpeakerTracksOffDeletesTracksAfterAnalysis`: URLs are nil and the files are gone.
  - `TerminologyServiceTests.testLLMOutputDroppingSpeakerPrefixesFallsBackToDeterministic` uses `StubLLMProvider`.
  - `TerminologyServiceTests.testPrefixCheckIgnoresTextChanges`.
- [ ] **Step 2: Run to verify failure.** Run: `-only-testing:CasablancaTests/TrackEnergyEnvelopeTests -only-testing:CasablancaTests/SpeakerAttributionTests -only-testing:CasablancaTests/SpeakerTranscriptBuilderTests -only-testing:CasablancaTests/PostTranscriptionPipelineTests -only-testing:CasablancaTests/TerminologyServiceTests`. Expected: build failure.
- [ ] **Step 3: Implement.**
  - `SpeakerAnalysis.live(defaults:)` reads the track URLs from the meeting, builds the envelopes off the main actor (`Task.detached`), attributes, and builds speakers. Diarization comes in A5: `diarization = .notRun` for now.
  - The pipeline order becomes: analyzer, then per-segment `dictionaryReplace`, then `TranscriptLineFormat.render` (when the analyzer returns nil, use `result.formattedTranscript` exactly), then `rawTranscript` = the render *before* replacement, then the LLM pass via the `knownSpeakers:` overload (display names), then save transcript, segments and speakers, then export, then compress the mix, then the tracks.
  - Track step: when `keepSpeakerTracks` is false, delete the track files and nil the URLs. Otherwise compress each track WAV through the same `compress` closure, repoint, and delete the WAV. When `keepOriginalWAV` is set, leave them as WAV.
- [ ] **Step 4: Run the tests from Step 2.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Measure voice processing (spec: left to the builder).** Do not enable `AVAudioInputNode.setVoiceProcessingEnabled` in this track. Record in the commit body that the bleed guard covers echo deterministically and that voice processing needs an on-device A/B (it changes the mic format and AGC). That check is listed in the pre-merge checklist as optional.
- [ ] **Step 6: Commit** `feat(speakers): attribute words to mic or system with a bleed guard`.

**Phase 2 handoff:** none (the `knownSpeakers` overload is additive; Track B's summarization does not call `correct`).

---

### Task A3: Word timestamps (point 12)

**Files:**
- Modify: `Casablanca/Services/Transcription/TranscriptionOptionsBuilder.swift` (read the setting, summary line)
- Modify: `Casablanca/Services/TranscriptionService.swift:27-39, 565-573, 523-548` (`TranscriptSegment.words`, map `segment.words`)
- Modify: `docs/transcription-benchmarks.md` (new dated section)
- Test: `CasablancaTests/TranscriptionOptionsBuilderTests.swift`, `CasablancaTests/TranscriptSegmentMergeTests.swift` (add)

**Interfaces:**
- Consumes: `AppPreferenceKey.wordTimestampsEnabled` (default true, Phase 0).
- Produces:
  - `TranscriptSegment.init(startTime:endTime:text:words: [TranscriptWord]? = nil)` and `let words: [TranscriptWord]?`.
  - `TranscriptionService.makeTranscriptWords(_ timings: [WordTiming]?) -> [TranscriptWord]?` (`static`, internal for tests). It maps `start`/`end` as Double, drops empty words, keeps Whisper's leading space in `text`, and returns nil for nil or empty input.
  - `TranscriptionOptionsBuilder.resolve` sets `decoding.wordTimestamps = bool(defaults, AppPreferenceKey.wordTimestampsEnabled, or: true)`. Because the command-line argument domain wins, `-wordTimestampsEnabled NO` works for benchmark A/B runs.

- [ ] **Step 1: Write the failing tests.**
  - `TranscriptionOptionsBuilderTests.testWordTimestampsDefaultOn`: an empty suite gives `decoding.wordTimestamps == true` and a summary line containing `wordTimestamps=true`.
  - `TranscriptionOptionsBuilderTests.testWordTimestampsOffViaSetting`.
  - `TranscriptionOptionsBuilderTests.testWordTimestampsStringArgumentNO`.
  - Update the existing default-pinning test that asserts `wordTimestamps == false` to `true`.
  - `TranscriptSegmentMergeTests.testMakeTranscriptWordsMapsTimingsAndDropsEmpty`.
  - `TranscriptSegmentMergeTests.testMakeTranscriptWordsNilForNil`.
- [ ] **Step 2: Run** `-only-testing:CasablancaTests/TranscriptionOptionsBuilderTests -only-testing:CasablancaTests/TranscriptSegmentMergeTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `makeTranscriptSegment` gains `words:`.
  - The final-segments map (`TranscriptionService.swift:565`) passes `segment.words`.
  - The live callback passes nil, because live words are not needed.
  - In the silent-chunk path, confirm that `chunker.updateSeekOffsetsForResults` shifts the word timings too. If not, offset the words by the same `seekOffsetIndex / 16000` as the segment.
- [ ] **Step 4: Run** the same command. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Measure on the benchmark harness** (`docs/transcription-benchmarks.md` "Reproducing").
  - Build Release with `scripts/build-release.sh`. Then run twice each:
    `…/Casablanca --benchmark-transcription "$HOME/Library/Application Support/Casablanca/Benchmarks/vzvz-44min.m4a" --benchmark-variant words-off -whisperModel openai_whisper-large-v3 -wordTimestampsEnabled NO`
    and the same command with `--benchmark-variant words-on -wordTimestampsEnabled YES`.
  - Score both with `scripts/transcript-agreement.py` against the reference. Append the table and the median `transcribeWall` delta % to a new `## Word timestamps, 2026-11-xx` section.
  - Decision rule (spec): the setting stays (Phase 0) default-on either way. If the delta is > 15 %, write the number in the doc and in the commit body as "Phase 3 CHANGELOG input".
  - If the benchmark audio is not on this machine, do not guess. Add the run to the pre-merge checklist and leave a `TODO(measure)` line in the doc section.
- [ ] **Step 6: Commit** `feat(transcription): keep word timestamps from WhisperKit`.

**Phase 2 handoff:** none.

---

### Task A4: Terminology prompt tokens and default model for new installs (point 11)

**Files:**
- Create: `Casablanca/Services/Transcription/WhisperPromptBuilder.swift`, `Casablanca/Services/Transcription/WhisperModelDefaults.swift`
- Modify: `Casablanca/Services/TranscriptionService.swift:138-144` (add the turbo option), `:496-520` (prompt tokens after load), `:565` (prompt-echo filter)
- Modify: `Casablanca/Services/Transcription/TranscriptionOptionsBuilder.swift` (hidden key `whisperPromptTerms`, summary line `promptTokens=<n>`)
- Modify: `Casablanca/CasablancaApp.swift:54` (one call next to `migrateLegacyAutoExportKeyIfNeeded`)
- Modify: `docs/transcription-benchmarks.md`
- Test: `CasablancaTests/WhisperPromptBuilderTests.swift`, `CasablancaTests/WhisperModelDefaultsTests.swift` (new), `CasablancaTests/TranscriptionOptionsBuilderTests.swift` (add)

**Interfaces:**
- Consumes: `TerminologyService.parse`, `TerminologyEntry.canonical`, `AppPreferenceKey.terminologyCorrectionEnabled/terminologyList/whisperModel/hasCompletedOnboarding`.
- Produces:
  - `enum WhisperPromptBuilder { static let maxPromptTokens = 223 /* Whisper n_text_ctx/2 − 1; satisfies the spec's ≤ 224 */; static func terms(enabled: Bool, raw: String) -> [String] /* canonical forms, list order, deduped case-insensitively */; static func tokens(for terms: [String], encode: (String) -> [Int], specialTokenBegin: Int, limit: Int = maxPromptTokens) -> [Int]; static func isPromptEcho(_ segmentText: String, terms: [String]) -> Bool }`
  - `tokens`: encode `" " + terms.prefix(k).joined(separator: ", ")` for the largest `k` whose filtered (`< specialTokenBegin`) count is `≤ limit`. Whole terms only, never a cut term. An empty result means no prompt.
  - `isPromptEcho`: true when the normalised (lowercase, letters and digits only) segment text equals the normalised joined prompt, or is a prefix of it at least 20 characters long. Such segments are dropped (Whisper's known prompt-hallucination on silence).
  - `TranscriptionOptionsBuilder.Key.promptTerms = "whisperPromptTerms"` (default true).
  - `TranscriptionService` sets `resolved.decoding.promptTokens = WhisperPromptBuilder.tokens(…, encode: { whisperKit.tokenizer?.encode(text: $0) ?? [] }, specialTokenBegin: whisperKit.tokenizer?.specialTokens.specialTokenBegin ?? Int.max)` after `loadWhisperKit`, only when terms are non-empty and the key is true.
  - `enum WhisperModelDefaults { static let legacyDefault = "openai_whisper-base"; static let newInstallDefault: String /* set in Step 5 */; static func pinIfNeeded(defaults: UserDefaults = .standard, storeExists: Bool) }`
  - `pinIfNeeded`: when `whisperModel` is absent, an existing install (`storeExists` or `hasCompletedOnboarding` or any of `llmProvider`/`obsidianVaultPath`/`terminologyList` present) gets `legacyDefault` written explicitly, and a new install gets `newInstallDefault` written explicitly. A present value is never touched. This is how "existing users keep their setting" holds without editing `AppPreferenceValue.defaultWhisperModel` in the shared `Meeting.swift`.

- [ ] **Step 1: Write the failing tests.**
  - `WhisperPromptBuilderTests.testTermsAreCanonicalInListOrder`: raw `"Wegiz: wegis, weggis\nBgZ\nMedicore"` gives `["Wegiz","BgZ","Medicore"]`.
  - `WhisperPromptBuilderTests.testDisabledGivesNoTerms`.
  - `WhisperPromptBuilderTests.testTokensNeverExceedLimit`: a fake encoder of one token per character and 300 terms gives `count ≤ 223`.
  - `WhisperPromptBuilderTests.testWholeTermsOnly`: decoding the fake tokens gives a string that ends at a term boundary.
  - `WhisperPromptBuilderTests.testSpecialTokensFilteredBeforeCounting`.
  - `WhisperPromptBuilderTests.testPromptEchoDetected`.
  - `WhisperPromptBuilderTests.testNormalSegmentNotEcho`.
  - `TranscriptionOptionsBuilderTests.testPromptTermsKeyDefaultTrueAndOverridable`.
  - `WhisperModelDefaultsTests.testExistingInstallPinsLegacyDefault`.
  - `WhisperModelDefaultsTests.testNewInstallGetsNewDefault`.
  - `WhisperModelDefaultsTests.testExplicitChoiceUntouched`.
  - `WhisperModelDefaultsTests.testIdempotent`.
  - `WhisperModelDefaultsTests.testNewInstallDefaultIsOffered`: `TranscriptionService.availableWhisperModels` contains `newInstallDefault`.
- [ ] **Step 2: Run** `-only-testing:CasablancaTests/WhisperPromptBuilderTests -only-testing:CasablancaTests/WhisperModelDefaultsTests -only-testing:CasablancaTests/TranscriptionOptionsBuilderTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Write the two files and wire the prompt tokens.
  - Apply the echo filter in the final-segments map.
  - `CasablancaApp` calls `WhisperModelDefaults.pinIfNeeded(storeExists: <the PersistenceController store URL exists>)` before any view reads `whisperModel`.
- [ ] **Step 4: Run** the same command. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Confirm the model ID and measure.**
  - List the folders of `https://huggingface.co/argmaxinc/whisperkit-coreml` and pick the turbo folder that WhisperKit `d447d308` can load. The candidate is `openai_whisper-large-v3-v20240930_turbo`; otherwise use `openai_whisper-large-v3_turbo`.
  - Run the harness twice each for `-whisperModel openai_whisper-large-v3` and `-whisperModel <turbo id>`, plus `-whisperPromptTerms NO/YES` on the chosen model, with the terminology list set.
  - Gate (same as the 2026-09 campaign): the turbo model's speed must be ≥ 1.25× large-v3's, with agreement to the reference ≤ large-v3's + 1 point. If it passes, `newInstallDefault` = the turbo id. Otherwise it is `openai_whisper-large-v3`, the best measured model.
  - Set the constant, add the option to `availableWhisperModels`, and write the table plus the decision into `docs/transcription-benchmarks.md` (Phase 3 CHANGELOG input). If the audio is unavailable, use `openai_whisper-large-v3` (measured in 2026-09) and list the turbo run in the pre-merge checklist.
- [ ] **Step 6: Commit** `feat(transcription): terminology prompt tokens and a measured default model for new installs`.

**Phase 2 handoff:** optionally align `AppPreferenceValue.defaultWhisperModel` (`Meeting.swift:51`, shared) to `WhisperModelDefaults.newInstallDefault` so the Settings picker fallback matches. It is not functionally required, because `pinIfNeeded` always writes the key.

---

### Task A5: Offline diarization with FluidAudio (point 3)

**Files:**
- Modify: `Casablanca.xcodeproj/project.pbxproj` (XCRemoteSwiftPackageReference "FluidAudio" + product dependency on the app target), `Casablanca.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Create: `Casablanca/Services/Speakers/SpeakerDiarizer.swift` (protocol + FluidAudio adapter), `Casablanca/Services/Speakers/SpeakerModelStatus.swift`, `Casablanca/Services/Speakers/SpeakerAnalysisStore.swift`
- Modify: `Casablanca/Services/Speakers/SpeakerAnalysis.swift`, `Casablanca/Services/Speakers/SpeakerTranscriptBuilder.swift`, `Casablanca/Views/Settings/SpeakerSettingsSection.swift` (Phase 0 placeholder → model status row + licence footer)
- Test: `CasablancaTests/SpeakerTranscriptBuilderTests.swift`, `CasablancaTests/SpeakerAnalysisStoreTests.swift` (new), `CasablancaTests/PostTranscriptionPipelineTests.swift`, `CasablancaTests/Speakers/FakeSpeakerDiarizer.swift` (new test helper)

**Interfaces:**
- Consumes: A2's `SpeakerAttribution`, `SpeakerAnalysisResult`, `DiarizationOutcome` and `SpeakerIDs`, plus `AppPreferenceKey.recogniseSpeakersEnabled`.
- Produces:
  - `struct DiarizedTurn: Equatable { var start: Double; var end: Double; var clusterKey: String }`
  - `struct DiarizationOutput: Equatable { var turns: [DiarizedTurn]; var embeddings: [String: [Float]] /* clusterKey → L2-normalised centroid; empty if the API exposes none */ }`
  - `protocol SpeakerDiarizing: Sendable { func prepareModels(progress: @escaping @Sendable (Double?) -> Void) async throws; func diarize(trackURL: URL) async throws -> DiarizationOutput; func embedding(trackURL: URL, ranges: [ClosedRange<Double>]) async throws -> [Float] }`
  - `final class FluidAudioDiarizer: SpeakerDiarizing`: models live under `Application Support/Casablanca/Models/FluidAudio` when the API lets us choose, else FluidAudio's default cache.
  - `@MainActor @Observable final class SpeakerModelStatus { enum State: Equatable { case notDownloaded, downloading(Double?), ready, failed(String) }; static let shared; var state: State }`
  - `SpeakerTranscriptBuilder.assignClusters(_ segments: [SpeakerSegment], turns: [DiarizedTurn], targetSpeakerID: String /* "others" or "me" for in-room */, minRunDuration: Double = 0.6) -> (segments: [SpeakerSegment], clusterOrder: [String /* clusterKey */])`
  - Mapping rule: a word whose segment has `targetSpeakerID` gets the turn with maximum overlap. With no overlap it gets the nearest turn within 0.5 s; otherwise it keeps `targetSpeakerID`. Cluster keys are renumbered `S1…` by first appearance. Runs shorter than 0.6 s are absorbed, then the segment is split on change, as in A2.
  - `struct SpeakerAnalysisRecord: Codable, Equatable { var meetingID: UUID; var diarization: DiarizationOutcome; var suggestions: [SpeakerNameSuggestion] }` and `struct SpeakerNameSuggestion: Codable, Equatable { var speakerID: String; var name: String; var evidence: String; var source: Source /* .transcript, .voiceProfile */; var score: Double? }`
  - `struct SpeakerAnalysisStore { init(directory: URL /* Application Support/Casablanca/Speakers */); func load(_ meetingID: UUID) -> SpeakerAnalysisRecord?; func save(_ record: SpeakerAnalysisRecord) throws; func delete(_ meetingID: UUID) }`. The sidecar holds no biometric data. A1's `deleteMeeting` change also calls `delete`; add that line to `MeetingListViewModel.deleteMeeting` in this task.

Decisions:
- **Which track to diarize:** the system track exists, so diarize it and map onto `"others"` words. With no system track and a mic track, diarize the mic and map onto `"me"` words (in-room).
- **In-room results:** with ≥ 2 room clusters, all speakers get source `.room`, `isUser` false, `Speaker N`. The user renames one of them in A6. With ≤ 1 cluster, or on failure, keep the single user speaker (Review Focus 1).
- **Settings:** `recogniseSpeakersEnabled == false` gives `.disabled` without calling the diarizer.
- **Failures:** any throw from `prepareModels` or `diarize` gives `.failed(reason)` and the A2 result unchanged (`Others`). It never throws out of the pipeline.

- [ ] **Step 1: Confirm the API and licences** (no code yet; record the findings at the top of `SpeakerDiarizer.swift` as a doc comment).
  - Package `https://github.com/FluidInference/FluidAudio.git`, `swift-tools-version 6.0`, `.macOS(.v14)`, no dependencies, Apache-2.0 (verified 2026-11-05). Pick the newest release tag at least 2 weeks old (0.17.x at writing) and pin it as an **exact version**, mirroring the pinned-WhisperKit policy.
  - Confirm that a Swift-6 package builds in this Swift 5 app target.
  - Confirm the offline API documented on 2026-11-05: `OfflineDiarizerManager(config: OfflineDiarizerConfig())`, `try await manager.prepareModels()`, `try await manager.process(audio: [Float])` / `process(_ url: URL)`, and `result.segments[i].speakerId/startTimeSeconds/endTimeSeconds`.
  - Check whether `prepareModels` takes a directory, whether it reports progress, and whether `process(url)` reads m4a. If not, decode with A2's AVAudioFile reader to 16 kHz `[Float]`.
  - Check whether the result exposes per-speaker embeddings (needed by A7). If not, find the embedding-extractor API for `embedding(trackURL:ranges:)`. If none exists, A7 Step 1 records it and A7 stops at the UI-less store.
  - Licences: read FluidAudio's `LICENSE` + `ThirdPartyLicenses/` and the Hugging Face model card of every downloaded Core ML bundle (pyannote community-1 segmentation, WeSpeaker embedding, VBx/PLDA). Allowed: Apache-2.0, MIT, BSD, and CC-BY-4.0 with attribution. Anything else (non-commercial, NVIDIA Open Model License) means stop and report to Youri.
  - Do not use Sortformer.
  - Write the list (file, licence, attribution line) into the commit body as Phase 3 CHANGELOG input.
- [ ] **Step 2: Write the failing tests** (pure; `FakeSpeakerDiarizer` returns canned turns or throws).
  - `SpeakerTranscriptBuilderTests.testSystemWordsGetClusterByMaxOverlap`.
  - `SpeakerTranscriptBuilderTests.testNearestTurnWithinHalfSecond`.
  - `SpeakerTranscriptBuilderTests.testWordFarFromAnyTurnStaysOthers`.
  - `SpeakerTranscriptBuilderTests.testClusterIDsNumberedByFirstAppearance`: keys `"spk_3","spk_1"` in that time order become `S1`, `S2`.
  - `SpeakerTranscriptBuilderTests.testMicWordsNeverGetClusters`.
  - `SpeakerTranscriptBuilderTests.testDutchClusterLabelsUseSpreker`.
  - `SpeakerTranscriptBuilderTests.testMicOnlyWithTwoRoomClustersProducesRoomSpeakers`.
  - `SpeakerTranscriptBuilderTests.testMicOnlyWithOneClusterLabelsUserOnly`.
  - `SpeakerAnalysisStoreTests.testRoundTrip`.
  - `SpeakerAnalysisStoreTests.testLoadMissingIsNil`.
  - `SpeakerAnalysisStoreTests.testDeleteRemovesFile`.
  - `PostTranscriptionPipelineTests.testDiarizationFailureStillCompletesWithOthers`: the fake throws `URLError(.notConnectedToInternet)` from `prepareModels`. Expect status `.completed`, the transcript has `Others:`, and the record shows `.failed`.
  - `PostTranscriptionPipelineTests.testRecogniseSpeakersOffSkipsDiarizer`: the fake records 0 calls.
  - `MeetingListViewModelTrackDeletionTests.testDeleteMeetingRemovesSpeakerSidecar`.
- [ ] **Step 3: Run** `-only-testing:CasablancaTests/SpeakerTranscriptBuilderTests -only-testing:CasablancaTests/SpeakerAnalysisStoreTests -only-testing:CasablancaTests/PostTranscriptionPipelineTests -only-testing:CasablancaTests/MeetingListViewModelTrackDeletionTests`. Expected: FAIL.
- [ ] **Step 4: Implement.**
  - Add the package.
  - `FluidAudioDiarizer` wraps the confirmed API behind the protocol.
  - `SpeakerAnalysis.live` takes `diarizer: SpeakerDiarizing = FluidAudioDiarizer()`. It updates `SpeakerModelStatus` and sets `TranscriptionService.statusMessage` to "Recognising speakers…" through an injected status closure. It logs diarization wall time next to the transcription timing line.
  - `SpeakerSettingsSection` shows the model state with a "Download now" button (calls `prepareModels`), the failure text, and a footer naming FluidAudio (Apache-2.0) and the model licences from Step 1.
- [ ] **Step 5: Run** the same command. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 6: In-app check.** Build, open Settings → Recording → the speaker section renders, and "Download now" reaches `ready`. Take a screenshot.
- [ ] **Step 7: Commit** `feat(speakers): offline diarization of the system track with FluidAudio`.

**Phase 2 handoff:** pbxproj package-reference conflicts are resolved in Task 2.0 by keeping all entries.

---

### Task A6: Speakers bar, clips, rename and name suggestions (point 4)

**Files:**
- Create: `Casablanca/Services/Speakers/SpeakerRenamer.swift`, `Casablanca/Services/Speakers/SpeakerClipSelector.swift`, `Casablanca/Services/Speakers/SpeakerNameProposer.swift`, `Casablanca/Views/MeetingDetail/SpeakersBar.swift`, `Casablanca/Views/MeetingDetail/SpeakerRenamePopover.swift`
- Modify: `Casablanca/Views/MeetingDetail/MeetingTranscriptTab.swift` (embed `SpeakersBar` above the transcript when `!meeting.speakers.isEmpty`), `Casablanca/Services/Speakers/SpeakerAnalysis.swift` (run the proposer after diarization and store suggestions)
- Test: `CasablancaTests/SpeakerRenamerTests.swift`, `CasablancaTests/SpeakerClipSelectorTests.swift`, `CasablancaTests/SpeakerNameProposerTests.swift` (new)

**Interfaces:**
- Consumes: `TranscriptLineFormat.renameSpeaker(in:from:to:)`, `AudioClipPlayer.shared`, `SpeakerAnalysisStore`, `SpeakerNameSuggestion`, `LLMProvider` / `LLMProviderFactory.current()`, `meeting.participants`.
- Produces:
  - `enum SpeakerRenamer { enum RenameError: Error, Equatable { case emptyName, unknownSpeaker }; static func sanitize(_ name: String) -> String /* trims, strips ":" and "[", caps at 40 chars */; @discardableResult static func rename(speakerID: String, to name: String, in meeting: Meeting) throws -> Bool /* true when it merged into an existing speaker */ }`
  - Rename rules:
    - Rewrite `meeting.transcript` with `renameSpeaker(old → new)` and `meeting.rawTranscript` likewise when non-nil.
    - Set `displayName`, `nameConfirmed = true`.
    - If another speaker already has the new display name, reassign this speaker's segments to that ID, drop this `SpeakerInfo`, and return `true`.
    - Never re-render.
  - `struct SpeakerClip: Equatable { var url: URL; var start: Double; var duration: Double }` and `enum SpeakerClipSelector { static func clip(for speakerID: String, meeting: Meeting) -> SpeakerClip?; static func talkTimeShares(_ segments: [SpeakerSegment]) -> [String: Double] }`
  - Clip rule: take the speaker's longest segment (the earliest on ties). `duration = min(5, length)` and `start = segment.start`. The URL is `micTrackFileURL` for `.microphone`/`.room` and `systemTrackFileURL` for `.system`. Return `nil` when the file does not exist, which hides ▶ (spec: unavailable when tracks are off).
  - `struct SpeakerNameProposer { init(providerFactory: @escaping () -> LLMProvider = { LLMProviderFactory.current() }); static let transcriptWindowSeconds = 600.0; static let maxPromptCharacters = 12_000; static func prompt(speakers: [SpeakerInfo], participants: [String], transcript: String) -> String; static func parse(_ response: String, speakers: [SpeakerInfo], participants: [String], transcript: String) -> [SpeakerNameSuggestion]; func propose(for meeting: Meeting) async -> [SpeakerNameSuggestion] }`
  - The prompt holds the participants, the non-user unconfirmed speaker labels, and the transcript lines with `seconds < 600`. It asks for JSON only: `[{"speakerID": "...", "name": "...|null", "evidence": "verbatim quote"}]`.
  - `parse` accepts a fenced or bare array. It keeps an entry only when:
    - `speakerID` is a known non-user unconfirmed speaker;
    - `name` is non-null, case-insensitively equal to a participant (or a first name of one) or occurring in the transcript;
    - `evidence` is non-empty and occurs in the transcript (whitespace- and case-normalised).
  - Malformed input yields `[]`, with no retry.
  - `SpeakersBar(meeting: Meeting, store: SpeakerAnalysisStore, onSpeakersChanged: ((Meeting) -> Void)? = nil)`. Each chip shows the name, the talk-time share as a percentage, ▶ (`AudioClipPlayer.shared.play(url:from:duration:)`, ■ while playing that URL), and a rename popover. The popover offers a text field plus participant suggestions, and suggested names with their evidence quote as one-tap "Use <name>" buttons. Accepting one calls `SpeakerRenamer.rename` and removes that suggestion from the sidecar. Nothing is applied without a tap.
  - The bar shows `DiarizationOutcome.failed(reason)` as a quiet caption: "Speaker recognition unavailable: …".

- [ ] **Step 1: Write the failing tests.**
  - `SpeakerRenamerTests.testRenameRewritesPrefixAndDisplayNameAndConfirms`.
  - `SpeakerRenamerTests.testRenamePreservesHandEditedText`: the transcript has an edited text line and `Spreker 1` inside text, and only the prefix changes.
  - `SpeakerRenamerTests.testRenameAlsoRewritesRawTranscript`.
  - `SpeakerRenamerTests.testRenameToExistingNameMergesSpeakers`: S2 → S1's name gives a return of `true`, one `SpeakerInfo` left, and all segments on S1.
  - `SpeakerRenamerTests.testEmptyNameRejected`.
  - `SpeakerRenamerTests.testSanitizeStripsColonBracketAndCaps40`.
  - `SpeakerClipSelectorTests.testPicksLongestSegmentCappedAtFiveSeconds`.
  - `SpeakerClipSelectorTests.testSystemSpeakerUsesSystemTrack`.
  - `SpeakerClipSelectorTests.testMicSpeakerUsesMicTrack`.
  - `SpeakerClipSelectorTests.testMissingTrackFileGivesNil`.
  - `SpeakerClipSelectorTests.testTalkTimeSharesSumToOne`.
  - `SpeakerNameProposerTests.testPromptIncludesParticipantsAndOnlyFirstTenMinutes`: a line at `[10:01]` is absent.
  - `SpeakerNameProposerTests.testPromptExcludesUserAndConfirmedSpeakers`.
  - `SpeakerNameProposerTests.testParsesFencedJSONWithEvidence`.
  - `SpeakerNameProposerTests.testDropsEvidenceNotInTranscript`.
  - `SpeakerNameProposerTests.testDropsNameNotInParticipantsOrTranscript`.
  - `SpeakerNameProposerTests.testNullNameDropped`.
  - `SpeakerNameProposerTests.testMalformedJSONGivesNoSuggestions`.
  - `SpeakerNameProposerTests.testProposeDoesNotMutateMeeting`: uses `StubLLMProvider`; `meeting.speakers` and `transcript` are unchanged.
- [ ] **Step 2: Run** `-only-testing:CasablancaTests/SpeakerRenamerTests -only-testing:CasablancaTests/SpeakerClipSelectorTests -only-testing:CasablancaTests/SpeakerNameProposerTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the three services and the two views.
  - `SpeakerAnalysis.live` calls `propose` only when diarization produced at least one unconfirmed non-user speaker and the meeting has participants or the transcript is non-empty. It saves the suggestions in the record.
  - Proposer failures are logged and leave the suggestions empty.
- [ ] **Step 4: Run** the same command. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: In-app check** (per `project_casablanca-view-verification`).
  - Build, then open a meeting seeded with speakers through a DEBUG fixture (the sample button pattern used by existing previews) or a real recording.
  - Confirm that the bar renders, ▶ plays and stops after about 5 s, rename updates the transcript prefixes, and a suggestion applies only on tap.
  - Run the constraint-pass probe on the transcript tab, and take a screenshot.
- [ ] **Step 6: Commit** `feat(speakers): speakers bar with clips, rename and confirmed name suggestions`.

**Phase 2 handoff:**
- I2 (master Task 2.2): wire `SpeakersBar.onSpeakersChanged` to Track B's "Regenerate summary with names" offer. Track A only calls the closure after every rename or merge, and shows no regenerate UI itself.
- I1: `MeetingTranscriptTab` gets timestamp links on top of this.

---

### Task A7: Voice profiles, off by default (point 16)

**Files:**
- Create: `Casablanca/Services/Speakers/VoiceProfileStore.swift`, `Casablanca/Services/Speakers/VoiceProfileKeyStore.swift`, `Casablanca/Services/Speakers/VoiceProfileMatcher.swift`, `Casablanca/Views/MeetingDetail/SaveVoiceProfileSheet.swift`
- Modify: `Casablanca/Views/Settings/PrivacySettingsSection.swift` (Phase 0 placeholder → toggle, explanation, profile list, delete, delete-all on turning off), `Casablanca/Views/MeetingDetail/SpeakersBar.swift` ("Remember voice…" menu item when enabled, the speaker is confirmed and its track exists), `Casablanca/Services/Speakers/SpeakerAnalysis.swift` (voice-match suggestions)
- Test: `CasablancaTests/VoiceProfileStoreTests.swift`, `CasablancaTests/VoiceProfileMatcherTests.swift`, `CasablancaTests/VoiceProfileKeyStoreTests.swift` (new)

**Interfaces:**
- Consumes: `AppPreferenceKey.voiceProfilesEnabled` (default false), `SpeakerDiarizing.embedding(trackURL:ranges:)` and `DiarizationOutput.embeddings` (A5), `SpeakerNameSuggestion(source: .voiceProfile)`.
- Produces:
  - `protocol SymmetricKeyStoring { func loadOrCreateKey() throws -> SymmetricKey; func deleteKey() throws }`
  - `struct KeychainSymmetricKeyStore: SymmetricKeyStoring`: service `com.casablanca.app.voiceprofiles`, account `aes-gcm-256`, `kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`. It uses the file-based login keychain (no `kSecUseDataProtectionKeychain`) so it works in an unsigned test host.
  - `final class InMemoryKeyStore: SymmetricKeyStoring` lives in the test file.
  - `struct VoiceProfile: Codable, Equatable, Identifiable { var id: UUID; var name: String; var centroid: [Float]; var sampleCount: Int; var consentedAt: Date; var createdAt: Date }`
  - `final class VoiceProfileStore { enum StoreError: Error, Equatable { case consentRequired, emptyEmbedding }; init(fileURL: URL /* Application Support/Casablanca/VoiceProfiles/profiles.sealed */, keyStore: SymmetricKeyStoring); func all() throws -> [VoiceProfile]; func save(name: String, embedding: [Float], consentGiven: Bool, now: Date = .now) throws -> VoiceProfile; func delete(id: UUID) throws; func deleteAll() throws }`
  - Storage: the whole JSON array is sealed with `AES.GCM.seal(…).combined` and written atomically with file protection. `save` on an existing name (case-insensitive) updates the centroid as an L2-normalised running mean and increments `sampleCount`. `deleteAll` removes the file and calls `deleteKey()`.
  - `enum VoiceProfileMatcher { static let defaultThreshold: Float = 0.80; static func cosine(_ a: [Float], _ b: [Float]) -> Float; static func suggestions(clusterEmbeddings: [String: [Float]], profiles: [VoiceProfile], threshold: Float = defaultThreshold) -> [SpeakerNameSuggestion] /* best profile per cluster ≥ threshold; evidence "Voice profile match"; score = cosine; each profile used at most once (highest score wins) */ }`

Decisions:
- **Threshold:** 0.80 cosine on L2-normalised 256-d WeSpeaker embeddings is a conservative starting value. A miss only costs a suggestion, and a match only ever suggests. Pinned by `testDefaultThresholdPinned`.
- **Gating:** matching runs only when `voiceProfilesEnabled` is true and profiles exist.
- **No stored embeddings:** cluster embeddings are never persisted. A profile's embedding is computed at save time from the kept track (up to 30 s of that speaker's longest segments). So with tracks off there is no "Remember voice", as the spec says.
- **Copy (exact):**
  - Toggle: "Remember voices (biometric data)".
  - Explanation: "Voice profiles are biometric personal data (GDPR/AVG art. 9). Casablanca stores them only on this Mac, encrypted, and only uses them to suggest names. Save a profile only with the person's explicit consent. Using this within an organisation requires a DPIA first."
  - Consent checkbox: "This person gave explicit consent".
  - Turn-off confirmation: "Turning this off deletes all saved voice profiles." with buttons "Delete profiles" / "Cancel"; Cancel leaves the toggle on.

- [ ] **Step 1: Confirm the embedding source** from A5 Step 1's finding. If FluidAudio exposes no embedding API, implement only the store, key store and matcher with their tests. Hide the "Remember voice…" UI, and say so in the commit body and the track report.
- [ ] **Step 2: Write the failing tests.**
  - `VoiceProfileStoreTests.testSaveRequiresConsent`: `consentGiven: false` throws `.consentRequired` and creates no file.
  - `VoiceProfileStoreTests.testRoundTrip`.
  - `VoiceProfileStoreTests.testFileIsEncrypted`: the raw bytes contain neither the UTF-8 of the name nor `"centroid"`.
  - `VoiceProfileStoreTests.testWrongKeyFailsToOpen`: a second `InMemoryKeyStore` makes `all()` throw.
  - `VoiceProfileStoreTests.testSameNameUpdatesNormalisedRunningMean`.
  - `VoiceProfileStoreTests.testDeleteOne`.
  - `VoiceProfileStoreTests.testDeleteAllRemovesFileAndKey`: the fake records `deleteKey`.
  - `VoiceProfileStoreTests.testEmptyEmbeddingRejected`.
  - `VoiceProfileMatcherTests.testCosineOfIdenticalIsOne`.
  - `VoiceProfileMatcherTests.testMatchAtThresholdSuggests`.
  - `VoiceProfileMatcherTests.testBelowThresholdNoSuggestion`.
  - `VoiceProfileMatcherTests.testEachProfileUsedOnce`.
  - `VoiceProfileMatcherTests.testDefaultThresholdPinned`.
  - `VoiceProfileKeyStoreTests.testLoadOrCreateIsStable`: uses a unique test service and deletes it in tearDown. `XCTSkip` on `errSecMissingEntitlement`.
  - `PostTranscriptionPipelineTests.testVoiceProfilesDisabledNeverMatches`: a fake store with profiles gives 0 voice suggestions when the preference is false (the default).
- [ ] **Step 3: Run** `-only-testing:CasablancaTests/VoiceProfileStoreTests -only-testing:CasablancaTests/VoiceProfileMatcherTests -only-testing:CasablancaTests/VoiceProfileKeyStoreTests -only-testing:CasablancaTests/PostTranscriptionPipelineTests`. Expected: FAIL.
- [ ] **Step 4: Implement** the store, key store, matcher, sheet (Save stays disabled until the consent checkbox is ticked) and Privacy section (list with name, created date and sample count; per-row delete; the turn-off flow). Add the match suggestions in `SpeakerAnalysis.live`.
- [ ] **Step 5: Run** the same command. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 6: In-app check.**
  - Settings → Recording shows Privacy with the toggle off by default.
  - Turn it on, save a profile from a confirmed speaker (Save disabled until consent), and see it listed and deletable.
  - Turn it off, confirm, and see the list empty and `profiles.sealed` gone.
  - Take a screenshot.
- [ ] **Step 7: Commit** `feat(speakers): opt-in encrypted voice profiles with consent`.

**Phase 2 handoff:** none.

---

## Track-A pre-merge checklist (Youri, on device)

Run on a Debug build from the track branch after A7. Each item is a yes/no.

1. **Teams call with 3+ people, speakers on (not headphones).** Your lines say your name. The remote lines split into `Speaker 1/2/…`, and no remote sentence is labelled as you (bleed guard).
2. **Same, with headphones.** Attribution is the same or better; there is no `Others` leakage into your lines.
3. **Pause and resume mid-call, then Stop.** Play a speaker clip from after the pause: it is that person and lines up with the transcript time.
4. **In-room meeting (system audio off or lid closed).** Room speakers get `Speaker N`. With one voice, everything is labelled as you. The pipeline never errors.
5. **First use offline** (Wi-Fi off, models not downloaded). The transcript completes with `Others`, and the bar says recognition is unavailable. With Wi-Fi back on, Settings → "Download now" reaches Ready.
6. **Rename `Speaker 1` from a suggestion and from free text.** Only the prefixes change, and a hand edit made before the rename survives. Renaming to an existing name merges the two.
7. **Clip ▶ plays about 5 s and stops.** With "Keep separate speaker tracks" off on a new meeting, ▶ and "Remember voice…" are hidden and no `.mic.m4a` / `.system.m4a` remain next to the recording.
8. **Delete a meeting.** Its `.m4a`, `.mic.m4a`, `.system.m4a` and `Speakers/<id>.json` are gone.
9. **Open a meeting recorded before this branch.** Transcript, summary, chat, search and export are unchanged, and no speakers bar appears.
10. **Voice profiles.** Off by default. Consent gates Save. Turning it off deletes everything after confirmation.
11. **Timing:** on a 45-minute meeting, total post-Stop time is at most 1.15× the transcription time logged before this branch. Read the `transcription finished` and diarization log lines.
12. **Benchmarks** (if not run by the agent): A3 Step 5 and A4 Step 5 runs, with numbers in `docs/transcription-benchmarks.md`.
13. **Optional:** A/B Apple voice processing on the mic (A2 Step 5). Only enable it in a follow-up if it measurably helps.
