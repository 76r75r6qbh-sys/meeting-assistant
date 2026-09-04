import Foundation
import SwiftData

/// Everything that has to happen after Whisper hands back a transcript, in the
/// order it has to happen in:
///
/// 1. terminology correction (when configured),
/// 2. the transcript onto the meeting, `.completed`, saved,
/// 3. the local transcript file,
/// 4. the automatic export,
/// 5. **then** the AAC re-encode of the recording.
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
    typealias TerminologyCorrector = @MainActor (String, [TerminologyEntry]) async -> String
    typealias TranscriptSaver = @MainActor (Meeting, TranscriptionResult) throws -> URL
    typealias Exporter = @MainActor (Meeting) async -> Void
    typealias Compressor = @MainActor (URL) async throws -> URL

    private let correctTerminology: TerminologyCorrector
    private let saveTranscript: TranscriptSaver
    private let export: Exporter
    private let compress: Compressor
    private let defaults: UserDefaults

    init(
        correctTerminology: @escaping TerminologyCorrector,
        saveTranscript: @escaping TranscriptSaver,
        export: @escaping Exporter,
        compress: @escaping Compressor,
        defaults: UserDefaults = .standard
    ) {
        self.correctTerminology = correctTerminology
        self.saveTranscript = saveTranscript
        self.export = export
        self.compress = compress
        self.defaults = defaults
    }

    /// The pipeline as the app runs it.
    static func live(
        terminologyService: TerminologyService,
        exportReporter: ExportStatusCenter?,
        defaults: UserDefaults = .standard
    ) -> PostTranscriptionPipeline {
        PostTranscriptionPipeline(
            correctTerminology: { transcript, entries in
                await terminologyService.correct(transcript, entries: entries)
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

        guard let finalTranscript = await applyTerminology(
            to: result.formattedTranscript,
            meeting: meeting,
            modelContext: modelContext
        ) else { return }

        meeting.transcript = finalTranscript
        meeting.status = .completed
        save(modelContext)

        let saveAndExportStart = ContinuousClock.now
        _ = try? saveTranscript(meeting, result)
        await export(meeting)
        logDuration("transcript save and export", since: saveAndExportStart)

        let compressionStart = ContinuousClock.now
        await compressRecording(wavURL: recordingURL, meeting: meeting, modelContext: modelContext)
        logDuration("recording compression", since: compressionStart)
    }

    // MARK: - Steps

    /// The transcript to store: corrected when the user has terminology
    /// configured, otherwise Whisper's own text. Returns nil when the meeting
    /// was deleted while the (potentially slow, LLM-backed) correction ran —
    /// there is then nothing left to write to.
    private func applyTerminology(
        to transcript: String,
        meeting: Meeting,
        modelContext: ModelContext
    ) async -> String? {
        let correctionEnabled = defaults.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled)
        let terminologyRaw = defaults.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        let entries = correctionEnabled ? TerminologyService.parse(terminologyRaw) : []

        guard !entries.isEmpty else {
            meeting.rawTranscript = nil
            return transcript
        }

        // Keep Whisper's own text: correction is lossy and the user can compare.
        meeting.rawTranscript = transcript
        save(modelContext)

        let terminologyStart = ContinuousClock.now
        let corrected = await correctTerminology(transcript, entries)
        logDuration("terminology correction", since: terminologyStart)

        guard isAlive(meeting) else { return nil }
        return corrected
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
