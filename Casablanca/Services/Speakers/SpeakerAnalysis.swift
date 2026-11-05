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

/// The live speaker step: reads the meeting's per-source tracks, attributes
/// Whisper's segments to the mic or the system track, and names the speakers.
///
/// Returns `nil` — and the pipeline then stores today's unlabelled transcript —
/// whenever labels cannot be trusted: speaker recognition is off, the meeting
/// has no mic track (an old meeting), or a track that is set cannot be read.
/// It never throws, so attribution can never fail a transcription.
enum SpeakerAnalysis {

    @MainActor
    static func live(defaults: UserDefaults = .standard) -> PostTranscriptionPipeline.SpeakerAnalyzer {
        { meeting, result in
            guard defaults.bool(forKey: AppPreferenceKey.recogniseSpeakersEnabled) else { return nil }
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
    ) async -> SpeakerAnalysisResult? {
        // Without the mic track there is nothing to tell the user apart by.
        guard let micTrackPath, !segments.isEmpty else { return nil }

        let attributed: (segments: [SpeakerSegment], hasSystem: Bool)? = await Task.detached(priority: .utility) {
            do {
                let mic = try TrackEnergyEnvelope.read(url: URL(fileURLWithPath: micTrackPath))
                // A set system track that cannot be read must not turn the far
                // end into the user: give up rather than treat it as mic-only.
                let system = try systemTrackPath.map { try TrackEnergyEnvelope.read(url: URL(fileURLWithPath: $0)) }
                let attribution = SpeakerAttribution(mic: mic, system: system, thresholds: thresholds)
                return (attribution.attribute(segments), system != nil)
            } catch {
                Log.transcription.error(
                    "Speaker attribution skipped; track unreadable: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }.value

        guard let attributed else { return nil }
        let speakers = SpeakerTranscriptBuilder.speakers(
            for: attributed.segments,
            language: language,
            userAliases: userAliases,
            hasSystemTrack: attributed.hasSystem,
            roomClusters: false
        )
        return SpeakerAnalysisResult(segments: attributed.segments, speakers: speakers, diarization: .notRun)
    }
}
