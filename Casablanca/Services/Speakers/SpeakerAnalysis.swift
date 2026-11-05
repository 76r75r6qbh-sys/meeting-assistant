import Foundation

/// How diarization of the system (or room) track went. Used from Task A5 on;
/// A2 only reports `.notRun`.
enum DiarizationOutcome: Codable, Equatable, Sendable {
    case notRun
    case disabled
    case succeeded(clusterCount: Int)
    case failed(reason: String)
    /// Diarization can never run on this Mac (macOS < 15); not retryable.
    case unsupported(reason: String)
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

    /// Whether unkept speaker tracks must stay for a retry: the analysis
    /// failed, or diarization failed for a reason that can pass (models
    /// missing or offline, a download or model error, the timeout). Not after
    /// success, `.disabled`, `.skipped` or `.unsupported` — those cannot
    /// improve on a retry.
    var keepsTracksForRetry: Bool {
        switch self {
        case .failed:
            return true
        case .analysed(let result):
            if case .failed = result.diarization { return true }
            return false
        case .disabled, .skipped:
            return false
        }
    }
}

/// The live speaker step: reads the meeting's per-source tracks, attributes
/// Whisper's segments to the mic or the system track, diarizes one track, and
/// names the speakers.
///
/// Anything but `.analysed` — and the pipeline then stores today's unlabelled
/// transcript — whenever labels cannot be trusted: speaker recognition is off
/// (`.disabled`), the meeting has no mic track (`.skipped`), or a track that is
/// set cannot be read (`.failed`). It never throws, so attribution can never
/// fail a transcription.
///
/// Diarization (Task A5) only refines an `.analysed` attribution. It runs on
/// the system track when there is one (its `"others"` words get clusters),
/// else on the mic track (in-room: the `"me"` words). Any failure — models not
/// downloadable (offline), a model error, the timeout — keeps the attribution
/// as it was (`Others`), with `diarization: .failed(reason)`, a status line and
/// `SpeakerModelStatus.failed` as the non-blocking notice. The outcome goes
/// into the meeting's `SpeakerAnalysisRecord` sidecar. Name suggestions
/// (Task A6) are not part of this step: they run afterwards, see
/// ``liveNameSuggester(defaults:store:proposer:)``.
enum SpeakerAnalysis {

    /// How long one diarization may take before the speaker step gives up on
    /// it. The run is then cancelled; FluidAudio checks cancellation between
    /// chunks, so it stops shortly after and cannot overlap the next meeting.
    static let defaultDiarizationTimeout: Duration = .seconds(900)

    @MainActor
    static func live(
        defaults: UserDefaults = .standard,
        diarizer: SpeakerDiarizing = FluidAudioDiarizer.shared,
        store: SpeakerAnalysisStore = SpeakerAnalysisStore(),
        modelStatus: SpeakerModelStatus = .shared,
        status: @escaping @MainActor (String) -> Void = { _ in },
        diarizationTimeout: Duration = defaultDiarizationTimeout
    ) -> PostTranscriptionPipeline.SpeakerAnalyzer {
        { meeting, result in
            guard defaults.bool(forKey: AppPreferenceKey.recogniseSpeakersEnabled) else { return .disabled }
            // Read everything on the main actor first; only values cross over.
            let meetingID = meeting.id
            let micTrackPath = meeting.micTrackFileURL
            let systemTrackPath = meeting.systemTrackFileURL
            let language = meeting.transcriptionLanguage
            let userAliases = AppPreferences.userNameAliases(in: defaults)
            let segments = result.segments
            let outcome = await analyze(
                micTrackPath: micTrackPath,
                systemTrackPath: systemTrackPath,
                segments: segments,
                language: language,
                userAliases: userAliases
            )
            guard case .analysed(let attributed) = outcome else { return outcome }

            let diarized = await diarize(
                attributed,
                micTrackPath: micTrackPath,
                systemTrackPath: systemTrackPath,
                language: language,
                userAliases: userAliases,
                diarizer: diarizer,
                modelStatus: modelStatus,
                status: status,
                timeout: diarizationTimeout
            )
            do {
                try store.save(SpeakerAnalysisRecord(meetingID: meetingID, diarization: diarized.diarization, suggestions: []))
            } catch {
                Log.transcription.error(
                    "Could not save the speaker analysis record: \(error.localizedDescription, privacy: .public)"
                )
            }
            return .analysed(diarized)
        }
    }

    // MARK: - Name suggestions (Task A6)

    /// The pipeline's name-suggestion step: after the transcript and status
    /// are saved, asks `proposer` in the background and writes the answers
    /// into the sidecar (the speakers bar refreshes on the store's change
    /// notification). Returns the background task, or `nil` when nothing runs:
    /// the user has not opted in (`SpeakerPreferenceKey`, default off — no
    /// automatic LLM call without consent), diarization did not succeed, or no
    /// unconfirmed non-user speaker is left. A failure or timeout is only a log
    /// line (the proposer's), and the sidecar stays as it was.
    @MainActor
    static func liveNameSuggester(
        defaults: UserDefaults = .standard,
        store: SpeakerAnalysisStore = SpeakerAnalysisStore(),
        proposer: SpeakerNameProposer = SpeakerNameProposer()
    ) -> PostTranscriptionPipeline.SpeakerNameSuggester {
        { meeting in
            guard defaults.bool(forKey: SpeakerPreferenceKey.suggestSpeakerNamesAutomatically) else { return nil }
            // Read the meeting now: it may be deleted while the LLM runs.
            let meetingID = meeting.id
            let speakers = meeting.speakers
            let participants = meeting.participants
            let transcript = meeting.transcript ?? ""
            guard let record = store.load(meetingID),
                  case .succeeded = record.diarization,
                  !SpeakerNameProposer.candidates(speakers).isEmpty,
                  !participants.isEmpty || !transcript.isEmpty
            else { return nil }
            return Task { @MainActor in
                let suggestions = await proposer.propose(
                    speakers: speakers,
                    participants: participants,
                    transcript: transcript
                )
                guard !suggestions.isEmpty else { return }
                // No sidecar any more means the meeting was deleted meanwhile.
                storeSuggestions(suggestions, meetingID: meetingID, store: store, createIfMissing: false)
            }
        }
    }

    /// The speakers bar's "Suggest names": runs `proposer` now, whatever the
    /// automatic setting, and stores the answers (replacing earlier ones),
    /// creating the sidecar for a meeting that has none. Never applies a name.
    @MainActor
    static func suggestNamesNow(
        for meeting: Meeting,
        store: SpeakerAnalysisStore,
        proposer: SpeakerNameProposer
    ) async -> [SpeakerNameSuggestion] {
        let meetingID = meeting.id
        let suggestions = await proposer.propose(for: meeting)
        storeSuggestions(suggestions, meetingID: meetingID, store: store, createIfMissing: !suggestions.isEmpty)
        return suggestions
    }

    @MainActor
    private static func storeSuggestions(
        _ suggestions: [SpeakerNameSuggestion],
        meetingID: UUID,
        store: SpeakerAnalysisStore,
        createIfMissing: Bool
    ) {
        var record: SpeakerAnalysisRecord
        if let existing = store.load(meetingID) {
            record = existing
        } else if createIfMissing {
            record = SpeakerAnalysisRecord(meetingID: meetingID, diarization: .notRun, suggestions: [])
        } else {
            return
        }
        record.suggestions = suggestions
        do {
            try store.save(record)
        } catch {
            Log.transcription.error(
                "Could not save speaker name suggestions: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// `attributed` with the diarizer's clusters applied, or unchanged with
    /// `diarization: .failed` when diarization fails. Never throws.
    @MainActor
    static func diarize(
        _ attributed: SpeakerAnalysisResult,
        micTrackPath: String?,
        systemTrackPath: String?,
        language: String,
        userAliases: [String],
        diarizer: SpeakerDiarizing,
        modelStatus: SpeakerModelStatus,
        status: @MainActor (String) -> Void,
        timeout: Duration
    ) async -> SpeakerAnalysisResult {
        let hasSystemTrack = systemTrackPath != nil
        let target = hasSystemTrack ? SpeakerIDs.others : SpeakerIDs.me
        guard let trackPath = systemTrackPath ?? micTrackPath,
              attributed.segments.contains(where: { $0.speakerID == target })
        else { return attributed }
        // Can never run here (macOS < 15): no per-meeting status lines,
        // Settings explains it.
        guard diarizer.isAvailable else {
            var unchanged = attributed
            unchanged.diarization = .unsupported(reason: SpeakerDiarizerError.unsupportedOS.localizedDescription)
            return unchanged
        }

        status("Recognising speakers\u{2026}")
        let start = ContinuousClock.now
        defer {
            let seconds = (ContinuousClock.now - start).timeInterval
            Log.transcription.notice(
                "diarization took \(String(format: "%.1f", seconds), privacy: .public)s"
            )
        }
        do {
            try await modelStatus.prepare(using: diarizer)
            let trackURL = URL(fileURLWithPath: trackPath)
            let output = try await withTimeout(timeout) {
                try await diarizer.diarize(trackURL: trackURL)
            }
            status(finishingStatus)
            return SpeakerTranscriptBuilder.diarizedResult(
                attributed,
                turns: output.turns,
                hasSystemTrack: hasSystemTrack,
                language: language,
                userAliases: userAliases
            )
        } catch SpeakerDiarizerError.unsupportedOS {
            status(finishingStatus)
            var unchanged = attributed
            unchanged.diarization = .unsupported(reason: SpeakerDiarizerError.unsupportedOS.localizedDescription)
            return unchanged
        } catch {
            let reason = error.localizedDescription
            Log.transcription.error("Diarization failed; keeping unsplit speakers: \(reason, privacy: .public)")
            status("Speakers could not be told apart; continuing without them\u{2026}")
            var unchanged = attributed
            unchanged.diarization = .failed(reason: reason)
            return unchanged
        }
    }

    /// Replaces "Recognising speakers…" once diarization succeeded.
    static let finishingStatus = "Finishing transcript\u{2026}"

    struct TimeoutError: LocalizedError {
        var errorDescription: String? { "Speaker recognition took too long." }
    }

    /// `operation`'s result, or `TimeoutError` once `timeout` passes —
    /// without waiting for an operation that ignores cancellation.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = OneShot<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let work = Task {
                do {
                    race.resume(.success(try await operation()))
                } catch {
                    race.resume(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                work.cancel()
                race.resume(.failure(TimeoutError()))
            }
            race.onResume { timer.cancel() }
        }
    }

    /// Resumes a continuation exactly once, whichever side gets there first.
    private final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var cleanup: (@Sendable () -> Void)?
        private var finished = false

        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func onResume(_ action: @escaping @Sendable () -> Void) {
            let runNow = lock.withLock { () -> Bool in
                if finished { return true }
                cleanup = action
                return false
            }
            if runNow { action() }
        }

        func resume(_ result: Result<T, Error>) {
            let taken = lock.withLock { () -> (CheckedContinuation<T, Error>?, (@Sendable () -> Void)?) in
                guard !finished else { return (nil, nil) }
                finished = true
                defer { continuation = nil; cleanup = nil }
                return (continuation, cleanup)
            }
            taken.1?()
            taken.0?.resume(with: result)
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
