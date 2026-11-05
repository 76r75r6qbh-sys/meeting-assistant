import Foundation
import SwiftData

/// Everything that has to happen after Whisper hands back a transcript, in the
/// order it has to happen in:
///
/// 1. speaker analysis (mic/system attribution; `nil` for an old meeting),
/// 2. terminology: the deterministic pass per segment, then the render, then
///    the provider pass, which must keep every speaker prefix,
/// 3. the transcript, segments and speakers onto the meeting, `.completed`, saved,
/// 4. the local transcript file,
/// 5. the automatic export,
/// 6. **then** the AAC re-encode of the recording,
/// 7. and last the speaker tracks: compressed like the mix, or deleted when
///    the user does not keep them.
///
/// Without a speaker analysis the transcript is `result.formattedTranscript`
/// byte for byte, exactly as before speakers existed.
///
/// Compression is last on purpose. It is minutes of CPU for a long meeting and
/// nothing downstream needs its result, so having it sit between the transcript
/// and the export (where it used to) delayed the two things the user is
/// actually waiting for. The meeting therefore already reads as `.completed`
/// while the re-encode is still running.
///
/// The four steps that touch the world are closures so the order — and the
/// compression failure path — are unit-testable without WhisperKit, AVFoundation,
/// an LLM, or an Obsidian vault.
@MainActor
struct PostTranscriptionPipeline {
    /// Speaker attribution for a finished transcription. Never throws: `nil`
    /// means "no labels", and the legacy transcript is stored.
    typealias SpeakerAnalyzer = @MainActor (Meeting, TranscriptionResult) async -> SpeakerAnalysisResult?
    /// The transcript, its terms, and the speaker names whose line prefixes
    /// the correction must keep (empty for an unlabelled transcript).
    typealias TerminologyCorrector = @MainActor (String, [TerminologyEntry], Set<String>) async -> String
    typealias TranscriptSaver = @MainActor (Meeting, TranscriptionResult) throws -> URL
    typealias Exporter = @MainActor (Meeting) async -> Void
    typealias Compressor = @MainActor (URL) async throws -> URL
    typealias TrackCompressor = Compressor

    private let analyzeSpeakers: SpeakerAnalyzer
    private let correctTerminology: TerminologyCorrector
    private let saveTranscript: TranscriptSaver
    private let export: Exporter
    private let compress: Compressor
    private let compressTrack: TrackCompressor
    private let defaults: UserDefaults

    /// `analyzeSpeakers` defaults to "no labels" and `compressTrack` to
    /// `compress`, so a caller that does not care about speakers keeps today's
    /// behaviour.
    init(
        analyzeSpeakers: @escaping SpeakerAnalyzer = { _, _ in nil },
        correctTerminology: @escaping TerminologyCorrector,
        saveTranscript: @escaping TranscriptSaver,
        export: @escaping Exporter,
        compress: @escaping Compressor,
        compressTrack: TrackCompressor? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.analyzeSpeakers = analyzeSpeakers
        self.correctTerminology = correctTerminology
        self.saveTranscript = saveTranscript
        self.export = export
        self.compress = compress
        self.compressTrack = compressTrack ?? compress
        self.defaults = defaults
    }

    /// The pipeline as the app runs it.
    static func live(
        terminologyService: TerminologyService,
        exportReporter: ExportStatusCenter?,
        defaults: UserDefaults = .standard
    ) -> PostTranscriptionPipeline {
        PostTranscriptionPipeline(
            analyzeSpeakers: SpeakerAnalysis.live(defaults: defaults),
            correctTerminology: { transcript, entries, knownSpeakers in
                await terminologyService.correct(transcript, entries: entries, knownSpeakers: knownSpeakers)
            },
            saveTranscript: { meeting, result in
                try TranscriptionService.saveTranscriptLocally(meeting: meeting, result: result)
            },
            export: { meeting in
                // `defaults` goes to the exporter too: it decides both WHETHER to
                // export and WHERE, so leaving it on `.standard` would let a
                // scratch-preference caller reach the user's real vault.
                await ExportService.exportAutomaticallyIfEnabled(
                    meeting,
                    defaults: defaults,
                    reporter: exportReporter
                )
            },
            compress: { wavURL in
                try await RecordingCompressor.compress(wavURL: wavURL)
            },
            defaults: defaults
        )
    }

    /// Runs the steps above for `meeting`. Never throws: every step either
    /// succeeds or is logged and skipped — a failed export or compression must
    /// not cost the user the transcript that already succeeded.
    ///
    /// The meeting can be deleted at any await inside here (the pipeline outlives
    /// the view that started it), so every write is preceded by an
    /// `isAlive(meeting)` check, exactly as the view-owned version did.
    func run(
        meeting: Meeting,
        result: TranscriptionResult,
        recordingURL: URL,
        modelContext: ModelContext
    ) async {
        guard isAlive(meeting) else { return }

        let speakerStart = ContinuousClock.now
        let analysis = await analyzeSpeakers(meeting, result)
        logDuration("speaker analysis", since: speakerStart)
        guard isAlive(meeting) else { return }

        guard let labelled = await applyTerminology(
            result: result,
            analysis: analysis,
            meeting: meeting,
            modelContext: modelContext
        ) else { return }

        meeting.transcript = labelled.transcript
        if let analysis {
            meeting.speakerSegments = labelled.segments
            meeting.speakers = analysis.speakers
        } else {
            // A re-transcription without labels must not keep stale ones.
            meeting.speakerSegmentsData = nil
            meeting.speakersData = nil
        }
        meeting.status = .completed
        save(modelContext)

        let saveAndExportStart = ContinuousClock.now
        _ = try? saveTranscript(meeting, result)
        await export(meeting)
        logDuration("transcript save and export", since: saveAndExportStart)

        let compressionStart = ContinuousClock.now
        await compressRecording(wavURL: recordingURL, meeting: meeting, modelContext: modelContext)
        logDuration("recording compression", since: compressionStart)

        let trackStart = ContinuousClock.now
        await finishSpeakerTracks(meeting: meeting, modelContext: modelContext)
        logDuration("speaker track compression", since: trackStart)
    }

    // MARK: - Steps

    /// The transcript to store, with the segments behind it.
    private struct Labelled {
        var transcript: String
        var segments: [SpeakerSegment]
    }

    /// The transcript to store: corrected when the user has terminology
    /// configured, otherwise Whisper's own text — rendered with speaker
    /// prefixes when there is an analysis. Returns nil when the meeting was
    /// deleted while the (potentially slow, LLM-backed) correction ran — there
    /// is then nothing left to write to.
    ///
    /// With an analysis, the deterministic replacements run per segment
    /// BEFORE the render, so a speaker name can never be rewritten and the
    /// stored segments carry the canonical terms; `rawTranscript` is the render
    /// before replacement.
    private func applyTerminology(
        result: TranscriptionResult,
        analysis: SpeakerAnalysisResult?,
        meeting: Meeting,
        modelContext: ModelContext
    ) async -> Labelled? {
        let correctionEnabled = defaults.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        let terminologyRaw = defaults.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        let entries = correctionEnabled ? TerminologyService.parse(terminologyRaw) : []

        let rawSegments = analysis?.segments ?? []
        let rawTranscript = analysis.map { TranscriptLineFormat.render($0.segments, speakers: $0.speakers) }
            ?? result.formattedTranscript

        guard !entries.isEmpty else {
            meeting.rawTranscript = nil
            return Labelled(transcript: rawTranscript, segments: rawSegments)
        }

        // Keep Whisper's own text: correction is lossy and the user can compare.
        meeting.rawTranscript = rawTranscript
        save(modelContext)

        var segments = rawSegments
        var transcript = rawTranscript
        var knownSpeakers: Set<String> = []
        if let analysis {
            segments = rawSegments.map { segment in
                var replaced = segment
                replaced.text = TerminologyService.dictionaryReplace(segment.text, entries: entries)
                return replaced
            }
            transcript = TranscriptLineFormat.render(segments, speakers: analysis.speakers)
            knownSpeakers = Set(
                analysis.speakers
                    .map { TranscriptLineFormat.sanitizedSpeakerName($0.displayName) }
                    .filter { !$0.isEmpty }
            )
        }

        let terminologyStart = ContinuousClock.now
        let corrected = await correctTerminology(transcript, entries, knownSpeakers)
        logDuration("terminology correction", since: terminologyStart)

        guard isAlive(meeting) else { return nil }
        return Labelled(transcript: corrected, segments: segments)
    }

    /// Re-encodes the finished WAV mixdown to AAC/m4a and repoints the meeting
    /// at the smaller file, deleting the WAV on success. Skipped entirely when
    /// the user has opted to keep the original WAV. On any failure the WAV is
    /// preserved and the meeting keeps pointing at it — the recording is never
    /// lost.
    private func compressRecording(wavURL: URL, meeting: Meeting, modelContext: ModelContext) async {
        guard !AppPreferences.keepOriginalWAV(in: defaults) else { return }
        // Only compress lossless WAV input; never re-compress an already-m4a file.
        guard wavURL.pathExtension.lowercased() == "wav" else { return }

        do {
            let m4aURL = try await compress(wavURL)

            // The meeting may have been deleted mid-compression; if so, leave the
            // newly written m4a to be cleaned up with the meeting's other files.
            guard isAlive(meeting) else { return }

            meeting.recordingFileURL = m4aURL.path
            save(modelContext)

            // WAV is no longer referenced — reclaim its disk space.
            bestEffort("delete WAV after compression", Log.recording) {
                try FileManager.default.removeItem(at: wavURL)
            }
            Log.recording.info("Compressed recording to AAC/m4a; deleted original WAV.")
        } catch {
            // Keep the WAV and leave the meeting pointing at it.
            Log.recording.error("Recording compression failed; keeping WAV: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The per-source speaker tracks, once nothing needs them as WAV any more.
    /// Not kept (`keepSpeakerTracks` off): deleted and un-referenced. Kept:
    /// compressed like the mix and repointed, unless the user keeps WAVs. A
    /// failed compression keeps that track's WAV. Never touches the mix.
    private func finishSpeakerTracks(meeting: Meeting, modelContext: ModelContext) async {
        guard isAlive(meeting) else { return }
        let keepTracks = defaults.bool(forKey: AppPreferenceKey.keepSpeakerTracks)

        guard keepTracks else {
            for path in [meeting.micTrackFileURL, meeting.systemTrackFileURL].compactMap({ $0 }) {
                bestEffort("delete speaker track", Log.recording) {
                    if FileManager.default.fileExists(atPath: path) {
                        try FileManager.default.removeItem(atPath: path)
                    }
                }
            }
            if meeting.micTrackFileURL != nil || meeting.systemTrackFileURL != nil {
                meeting.micTrackFileURL = nil
                meeting.systemTrackFileURL = nil
                save(modelContext)
            }
            return
        }

        guard !AppPreferences.keepOriginalWAV(in: defaults) else { return }
        if let path = meeting.micTrackFileURL, let compressed = await compressTrackFile(atPath: path) {
            guard isAlive(meeting) else { return }
            meeting.micTrackFileURL = compressed
            save(modelContext)
            deleteCompressedWAV(atPath: path)
        }
        if let path = meeting.systemTrackFileURL, let compressed = await compressTrackFile(atPath: path) {
            guard isAlive(meeting) else { return }
            meeting.systemTrackFileURL = compressed
            save(modelContext)
            deleteCompressedWAV(atPath: path)
        }
    }

    /// The compressed track's path, or nil when the track is not a WAV, is
    /// missing, or failed to compress (it then stays as it is).
    private func compressTrackFile(atPath path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "wav",
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        do {
            return try await compressTrack(url).path
        } catch {
            Log.recording.error(
                "Speaker track compression failed; keeping WAV: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func deleteCompressedWAV(atPath path: String) {
        bestEffort("delete speaker track WAV after compression", Log.recording) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Helpers

    /// Whether the meeting is still in a context, i.e. has not been deleted out
    /// from under a long-running step.
    private func isAlive(_ meeting: Meeting) -> Bool {
        meeting.modelContext != nil
    }

    private func save(_ modelContext: ModelContext) {
        try? modelContext.save()
    }

    /// Logs how long one post-transcription phase took. Transcription itself
    /// reports its own phases (see `TranscriptionTimingReport`); these lines
    /// account for the work that runs after it, which is otherwise invisible.
    private func logDuration(_ phase: String, since start: ContinuousClock.Instant) {
        let seconds = (ContinuousClock.now - start).timeInterval
        Log.transcription.notice(
            "\(phase, privacy: .public) took \(String(format: "%.1f", seconds), privacy: .public)s"
        )
    }
}
