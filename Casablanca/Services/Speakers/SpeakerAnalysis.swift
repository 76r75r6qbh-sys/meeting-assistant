import Foundation

/// How diarization of the system (or room) track went. Used from Task A5 on;
/// A2 only reports `.notRun`.
enum DiarizationOutcome: Codable, Equatable, Sendable {
    case notRun
    case disabled
    case succeeded(clusterCount: Int)
    case failed(reason: String)
}

/// What the speaker step hands the pipeline.
struct SpeakerAnalysisResult: Equatable {
    var segments: [SpeakerSegment]
    var speakers: [SpeakerInfo]
    var diarization: DiarizationOutcome
}

/// What the speaker step did. Only `.analysed` labels the transcript; every
/// other case stores today's unlabelled transcript. The cases differ in what
/// happens to the speaker tracks when the user does not keep them: after
/// `.disabled`, `.skipped` or `.analysed` they are deleted (nothing will use
/// them, and they hold the remote participants' voices); after `.failed` they
/// are kept so a retry can still label the meeting.
enum SpeakerAnalysisOutcome: Equatable {
    /// Speaker recognition is switched off.
    case disabled
    /// Nothing to analyse: no mic track (an old meeting) or no segments.
    case skipped
    /// A track that is set could not be read, or attribution failed.
    case failed(reason: String)
    case analysed(SpeakerAnalysisResult)

    var result: SpeakerAnalysisResult? {
        if case .analysed(let result) = self { return result }
        return nil
    }
}

/// The live speaker step: reads the meeting's per-source tracks, attributes
/// Whisper's segments to the mic or the system track, and names the speakers.
///
/// Anything but `.analysed` — and the pipeline then stores today's unlabelled
/// transcript — whenever labels cannot be trusted: speaker recognition is off
/// (`.disabled`), the meeting has no mic track (`.skipped`), or a track that is
/// set cannot be read (`.failed`). It never throws, so attribution can never
/// fail a transcription.
enum SpeakerAnalysis {

    @MainActor
    static func live(defaults: UserDefaults = .standard) -> PostTranscriptionPipeline.SpeakerAnalyzer {
        { meeting, result in
            guard defaults.bool(forKey: AppPreferenceKey.recogniseSpeakersEnabled) else { return .disabled }
            // Read everything on the main actor first; only values cross over.
            let micTrackPath = meeting.micTrackFileURL
            let systemTrackPath = meeting.systemTrackFileURL
            let language = meeting.transcriptionLanguage
            let userAliases = AppPreferences.userNameAliases(in: defaults)
            let segments = result.segments
            return await analyze(
                micTrackPath: micTrackPath,
                systemTrackPath: systemTrackPath,
                segments: segments,
                language: language,
                userAliases: userAliases
            )
        }
    }

    /// The analysis itself, minus the meeting and the preferences. Envelope
    /// reading and attribution run off the main actor.
    static func analyze(
        micTrackPath: String?,
        systemTrackPath: String?,
        segments: [TranscriptSegment],
        language: String,
        userAliases: [String],
        thresholds: SpeakerAttribution.Thresholds = .default
    ) async -> SpeakerAnalysisOutcome {
        // Without the mic track there is nothing to tell the user apart by.
        guard let micTrackPath, !segments.isEmpty else { return .skipped }

        let attempt: Result<(segments: [SpeakerSegment], hasSystem: Bool), Error> = await Task.detached(priority: .utility) {
            do {
                let mic = try TrackEnergyEnvelope.read(url: URL(fileURLWithPath: micTrackPath))
                // A set system track that cannot be read must not turn the far
                // end into the user: give up rather than treat it as mic-only.
                let system = try systemTrackPath.map { try TrackEnergyEnvelope.read(url: URL(fileURLWithPath: $0)) }
                let attribution = SpeakerAttribution(mic: mic, system: system, thresholds: thresholds)
                return .success((attribution.attribute(segments), system != nil))
            } catch {
                return .failure(error)
            }
        }.value

        let attributedSegments: (segments: [SpeakerSegment], hasSystem: Bool)
        switch attempt {
        case .success(let value):
            attributedSegments = value
        case .failure(let error):
            Log.transcription.error(
                "Speaker attribution failed; track unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(reason: error.localizedDescription)
        }
        let attributed = attributedSegments
        let speakers = SpeakerTranscriptBuilder.speakers(
            for: attributed.segments,
            language: language,
            userAliases: userAliases,
            hasSystemTrack: attributed.hasSystem,
            roomClusters: false
        )
        return .analysed(SpeakerAnalysisResult(segments: attributed.segments, speakers: speakers, diarization: .notRun))
    }
}
