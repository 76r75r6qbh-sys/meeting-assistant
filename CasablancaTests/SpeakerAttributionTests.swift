import XCTest
@testable import Casablanca

/// Pins the energy attribution and the bleed guard with synthetic signals only
/// (seeded LCG noise, 16 kHz, built in memory). Every threshold the algorithm
/// uses is asserted in `testDefaultThresholdsArePinned`.
final class SpeakerAttributionTests: XCTestCase {

    // MARK: - Thresholds

    func testDefaultThresholdsArePinned() {
        let thresholds = SpeakerAttribution.Thresholds.default
        XCTAssertEqual(thresholds.micGain, 1.35)
        XCTAssertEqual(thresholds.systemGain, 0.8)
        XCTAssertEqual(thresholds.silenceFloorRMS, 0.004)
        XCTAssertEqual(thresholds.micShareForMic, 0.65)
        XCTAssertEqual(thresholds.micShareForSystem, 0.35)
        XCTAssertEqual(thresholds.bleedCorrelation, 0.80)
        XCTAssertEqual(thresholds.bleedMaxLagFrames, 4)
        XCTAssertEqual(thresholds.bleedMinWindow, 0.6)
        XCTAssertEqual(thresholds.minRunDuration, 0.6)
        XCTAssertEqual(thresholds, SpeakerAttribution.Thresholds())
        XCTAssertEqual(EnergyEnvelope.frameDuration, 0.05)
        XCTAssertEqual(SpeakerIDs.me, "me")
        XCTAssertEqual(SpeakerIDs.others, "others")
        XCTAssertEqual(SpeakerIDs.cluster(3), "S3")
    }

    // MARK: - Span source

    func testUserAloneIsMic() {
        let mic = SyntheticSignal.noise(seed: 1, count: 32_000, amplitude: 0.3)
        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(SyntheticSignal.silence(seconds: 2)))
        XCTAssertEqual(attribution.source(from: 0, to: 2), .microphone)
    }

    func testRemoteAloneIsSystem() {
        let system = SyntheticSignal.noise(seed: 2, count: 32_000, amplitude: 0.3)
        let attribution = SpeakerAttribution(mic: envelope(SyntheticSignal.silence(seconds: 2)), system: envelope(system))
        XCTAssertEqual(attribution.source(from: 0, to: 2), .system)
    }

    func testRemoteVoiceLeakingIntoMicIsAttributedToSystem() {
        let count = 32_000
        // 4 Hz on/off: 125 ms of noise, 125 ms of silence.
        let carrier = SyntheticSignal.noise(seed: 3, count: count, amplitude: 0.3)
        let system = carrier.enumerated().map { index, sample in (index / 2_000) % 2 == 0 ? sample : 0 }
        // The mic hears the speakers 100 ms late, a little attenuated, over its own hiss.
        let delay = 1_600
        let hiss = SyntheticSignal.noise(seed: 4, count: count, amplitude: 0.001)
        let mic = (0..<count).map { index in (index >= delay ? 0.9 * system[index - delay] : 0) + hiss[index] }

        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(system))

        let share = try? XCTUnwrap(attribution.micShare(from: 0, to: 2))
        XCTAssertGreaterThan(share ?? 0, 0.65, "On energy alone this would read as the user")
        XCTAssertEqual(attribution.source(from: 0, to: 2), .system, "…but the bleed guard sees the echo")
    }

    func testDoubleTalkUncorrelatedStaysMic() {
        let mic = SyntheticSignal.noise(seed: 5, count: 32_000, amplitude: 0.3)
        let system = SyntheticSignal.noise(seed: 6, count: 32_000, amplitude: 0.1)
        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(system))
        XCTAssertEqual(attribution.source(from: 0, to: 2), .microphone)
    }

    func testSilenceIsUndetermined() {
        let attribution = SpeakerAttribution(
            mic: envelope(SyntheticSignal.silence(seconds: 2)),
            system: envelope(SyntheticSignal.silence(seconds: 2))
        )
        XCTAssertEqual(attribution.source(from: 0, to: 2), .undetermined)
        XCTAssertEqual(attribution.source(from: 10, to: 11), .undetermined, "Past the end of the tracks is silence")
    }

    // MARK: - Words

    func testUndeterminedWordInheritsPreviousSource() {
        // Mic speaks 0–1 s, silence 1–2 s, then the remote side 2–4 s.
        let mic = SyntheticSignal.gated(SyntheticSignal.noise(seed: 7, count: 64_000, amplitude: 0.3), keep: [(0, 1)])
        let system = SyntheticSignal.gated(SyntheticSignal.noise(seed: 8, count: 64_000, amplitude: 0.3), keep: [(2, 4)])
        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(system))
        let words = [
            TranscriptWord(start: 0, end: 0.5, text: " so"),
            TranscriptWord(start: 0.5, end: 1.0, text: " what"),
            TranscriptWord(start: 1.05, end: 1.85, text: " now"),
        ]

        XCTAssertEqual(attribution.source(from: 1.05, to: 1.85), .undetermined)
        XCTAssertEqual(attribution.resolvedSources(for: words), [.microphone, .microphone, .microphone])

        // The first word inherits the next determined one.
        let leading = [
            TranscriptWord(start: 1.05, end: 1.85, text: " hm"),
            TranscriptWord(start: 2.0, end: 2.5, text: " yes"),
        ]
        XCTAssertEqual(attribution.resolvedSources(for: leading), [.system, .system])

        let output = attribution.attribute([segment(0, 1.85, " so what now", words: words)])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.speakerID, SpeakerIDs.me)
    }

    func testShortFlipUnder0_6sIsAbsorbed() {
        let mic = SyntheticSignal.gated(
            SyntheticSignal.noise(seed: 9, count: 48_000, amplitude: 0.3),
            keep: [(0, 1.2), (1.6, 3)]
        )
        let system = SyntheticSignal.gated(
            SyntheticSignal.noise(seed: 10, count: 48_000, amplitude: 0.3),
            keep: [(1.2, 1.6)]
        )
        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(system))
        let words = [
            TranscriptWord(start: 0, end: 0.6, text: " one"),
            TranscriptWord(start: 0.6, end: 1.2, text: " two"),
            TranscriptWord(start: 1.2, end: 1.6, text: " three"),
            TranscriptWord(start: 1.6, end: 2.2, text: " four"),
            TranscriptWord(start: 2.2, end: 3.0, text: " five"),
        ]
        XCTAssertEqual(attribution.source(from: 1.2, to: 1.6), .system, "The blip itself is the remote side")

        let output = attribution.attribute([segment(0, 3, " one two three four five", words: words)])

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.speakerID, "me")
        XCTAssertEqual(output.first?.text, " one two three four five", "An unsplit segment keeps Whisper's text")
        XCTAssertEqual(output.first?.start, 0)
        XCTAssertEqual(output.first?.end, 3)
        XCTAssertEqual(output.first?.words, words)
    }

    func testSourceChangeOver0_6sSplitsSegment() {
        let mic = SyntheticSignal.gated(SyntheticSignal.noise(seed: 11, count: 48_000, amplitude: 0.3), keep: [(0, 1.5)])
        let system = SyntheticSignal.gated(SyntheticSignal.noise(seed: 12, count: 48_000, amplitude: 0.3), keep: [(1.5, 3)])
        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(system))
        let words = [
            TranscriptWord(start: 0.1, end: 0.7, text: " Hello"),
            TranscriptWord(start: 0.7, end: 1.5, text: " there."),
            TranscriptWord(start: 1.5, end: 2.2, text: " How"),
            TranscriptWord(start: 2.2, end: 2.9, text: " are"),
        ]

        let output = attribution.attribute([segment(0, 3, " Hello there. How are", words: words)])

        XCTAssertEqual(output.map(\.speakerID), ["me", "others"])
        XCTAssertEqual(output.map(\.start), [0.1, 1.5])
        XCTAssertEqual(output.map(\.end), [1.5, 2.9])
        XCTAssertEqual(output.map(\.text), ["Hello there.", "How are"])
        XCTAssertEqual(output.flatMap { $0.words ?? [] }, words, "All words survive, in order")
    }

    /// Split text is built from words, so it must get the same cleaning as
    /// Whisper's segment text: control tokens out, whitespace collapsed, no
    /// space before punctuation, trimmed.
    func testSplitSegmentTextIsCleanedLikeWhisperSegments() {
        let mic = SyntheticSignal.gated(SyntheticSignal.noise(seed: 30, count: 48_000, amplitude: 0.3), keep: [(0, 1.5)])
        let system = SyntheticSignal.gated(SyntheticSignal.noise(seed: 31, count: 48_000, amplitude: 0.3), keep: [(1.5, 3)])
        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(system))
        let words = [
            TranscriptWord(start: 0.0, end: 0.1, text: "<|en|>"),
            TranscriptWord(start: 0.1, end: 0.7, text: " Hello  "),
            TranscriptWord(start: 0.7, end: 1.5, text: " there ."),
            TranscriptWord(start: 1.5, end: 2.2, text: "<|0.00|> How"),
            TranscriptWord(start: 2.2, end: 2.9, text: "  are\tyou ?<|endoftext|>"),
        ]

        let output = attribution.attribute([segment(0, 3, "Hello there. How are you?", words: words)])

        XCTAssertEqual(output.map(\.speakerID), ["me", "others"])
        XCTAssertEqual(output.map(\.text), ["Hello there.", "How are you?"])
        XCTAssertEqual(output.flatMap { $0.words ?? [] }, words, "Words themselves stay raw")
        XCTAssertEqual(WhisperTextCleaner.clean("<|en|> Hello  there ,  world !"), "Hello there, world!")
    }

    func testSegmentWithoutWordsUsesSegmentLevelAttribution() {
        let mic = SyntheticSignal.gated(SyntheticSignal.noise(seed: 13, count: 64_000, amplitude: 0.3), keep: [(0, 2)])
        let system = SyntheticSignal.gated(SyntheticSignal.noise(seed: 14, count: 64_000, amplitude: 0.3), keep: [(2, 4)])
        let attribution = SpeakerAttribution(mic: envelope(mic), system: envelope(system))

        let output = attribution.attribute([
            segment(0, 2, " Mine."),
            segment(2, 4, " Theirs."),
            segment(5, 6, " Silent."),
        ])

        XCTAssertEqual(output.map(\.speakerID), ["me", "others", "others"],
                       "An all-undetermined segment is .system when a system envelope exists")
        XCTAssertEqual(output.map(\.text), [" Mine.", " Theirs.", " Silent."])
        XCTAssertEqual(output.map(\.start), [0, 2, 5])
        XCTAssertNil(output.first?.words)
    }

    func testMicOnlyMeetingAttributesEverythingToMic() {
        let mic = SyntheticSignal.gated(SyntheticSignal.noise(seed: 15, count: 48_000, amplitude: 0.3), keep: [(0, 1)])
        let attribution = SpeakerAttribution(mic: envelope(mic), system: nil)

        let output = attribution.attribute([
            segment(0, 1, " Spoken."),
            segment(1.5, 3, " Silent."),
        ])

        XCTAssertEqual(output.map(\.speakerID), ["me", "me"])
    }

    func testNoEnvelopesLeavesSpeakerNil() {
        let attribution = SpeakerAttribution(mic: nil, system: nil)
        let words = [TranscriptWord(start: 0, end: 1, text: " hi")]

        let output = attribution.attribute([segment(0, 1, " hi", words: words), segment(1, 2, " there")])

        XCTAssertEqual(output, [
            SpeakerSegment(start: 0, end: 1, speakerID: nil, text: " hi", words: words),
            SpeakerSegment(start: 1, end: 2, speakerID: nil, text: " there", words: nil),
        ])
    }

    func testDeterministic() {
        let mic = SyntheticSignal.gated(SyntheticSignal.noise(seed: 16, count: 48_000, amplitude: 0.3), keep: [(0, 1.5)])
        let system = SyntheticSignal.gated(SyntheticSignal.noise(seed: 17, count: 48_000, amplitude: 0.3), keep: [(1.5, 3)])
        let words = [
            TranscriptWord(start: 0, end: 0.8, text: " a"),
            TranscriptWord(start: 0.8, end: 1.5, text: " b"),
            TranscriptWord(start: 1.5, end: 3, text: " c"),
        ]
        let input = [segment(0, 3, " a b c", words: words), segment(3, 4, " d")]

        let first = SpeakerAttribution(mic: envelope(mic), system: envelope(system)).attribute(input)
        let second = SpeakerAttribution(mic: envelope(mic), system: envelope(system)).attribute(input)

        XCTAssertEqual(first, second)
    }

    // MARK: - Live analysis over track files

    func testAnalyzeLabelsUserAndOthersFromTrackFiles() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mic = directory.appendingPathComponent("m.mic.wav")
        let system = directory.appendingPathComponent("m.system.wav")
        try SyntheticSignal.writeWAV(
            SyntheticSignal.gated(SyntheticSignal.noise(seed: 20, count: 64_000, amplitude: 0.3), keep: [(0, 2)]), to: mic
        )
        try SyntheticSignal.writeWAV(
            SyntheticSignal.gated(SyntheticSignal.noise(seed: 21, count: 64_000, amplitude: 0.3), keep: [(2, 4)]), to: system
        )

        let result = await SpeakerAnalysis.analyze(
            micTrackPath: mic.path,
            systemTrackPath: system.path,
            segments: [segment(0, 2, "Mine."), segment(2, 4, "Theirs.")],
            language: "nl-NL",
            userAliases: ["Youri"]
        )

        XCTAssertEqual(result?.segments.map(\.speakerID), ["me", "others"])
        XCTAssertEqual(result?.speakers.map(\.displayName), ["Youri", "Anderen"])
        XCTAssertEqual(result?.diarization, .notRun)
    }

    func testAnalyzeWithUnreadableSystemTrackFallsBackToNoLabels() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mic = directory.appendingPathComponent("m.mic.wav")
        try SyntheticSignal.writeWAV(SyntheticSignal.noise(seed: 22, count: 16_000, amplitude: 0.3), to: mic)
        let garbage = directory.appendingPathComponent("m.system.wav")
        try Data("not audio".utf8).write(to: garbage)

        let unreadable = await SpeakerAnalysis.analyze(
            micTrackPath: mic.path, systemTrackPath: garbage.path,
            segments: [segment(0, 1, "x")], language: "en", userAliases: []
        )
        let missing = await SpeakerAnalysis.analyze(
            micTrackPath: mic.path, systemTrackPath: directory.appendingPathComponent("gone.wav").path,
            segments: [segment(0, 1, "x")], language: "en", userAliases: []
        )
        let noMic = await SpeakerAnalysis.analyze(
            micTrackPath: nil, systemTrackPath: nil,
            segments: [segment(0, 1, "x")], language: "en", userAliases: []
        )

        XCTAssertNil(unreadable, "An unreadable system track must not turn the far end into the user")
        XCTAssertNil(missing)
        XCTAssertNil(noMic, "No mic track (an old meeting) means no labels")
    }

    func testAnalyzeMicOnlyLabelsTheUser() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mic = directory.appendingPathComponent("m.mic.wav")
        try SyntheticSignal.writeWAV(SyntheticSignal.noise(seed: 23, count: 16_000, amplitude: 0.3), to: mic)

        let result = await SpeakerAnalysis.analyze(
            micTrackPath: mic.path, systemTrackPath: nil,
            segments: [segment(0, 1, "x"), segment(1, 2, "y")], language: "en", userAliases: []
        )

        XCTAssertEqual(result?.segments.map(\.speakerID), ["me", "me"])
        XCTAssertEqual(result?.speakers.map(\.displayName), ["Me"])
    }

    @MainActor
    func testLiveAnalyzerIsOffWhenSpeakerRecognitionIsDisabled() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mic = directory.appendingPathComponent("m.mic.wav")
        try SyntheticSignal.writeWAV(SyntheticSignal.noise(seed: 24, count: 16_000, amplitude: 0.3), to: mic)
        let defaults = UserDefaults(suiteName: "speaker-analysis-\(UUID().uuidString)")!
        let meeting = Meeting(title: "t", date: Date(timeIntervalSince1970: 0))
        meeting.micTrackFileURL = mic.path
        let transcription = TranscriptionResult(segments: [segment(0, 1, "x")], fullText: "x", duration: 1)

        defaults.set(false, forKey: AppPreferenceKey.recogniseSpeakersEnabled)
        let off = await SpeakerAnalysis.live(defaults: defaults)(meeting, transcription)
        defaults.set(true, forKey: AppPreferenceKey.recogniseSpeakersEnabled)
        defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)
        let on = await SpeakerAnalysis.live(defaults: defaults)(meeting, transcription)

        XCTAssertNil(off)
        XCTAssertEqual(on?.speakers.map(\.displayName), ["Youri"])
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Helpers

    private func envelope(_ samples: [Float]) -> EnergyEnvelope {
        TrackEnergyEnvelope.envelope(samples: samples)
    }

    private func segment(_ start: Double, _ end: Double, _ text: String, words: [TranscriptWord]? = nil) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: end, text: text, words: words)
    }
}
