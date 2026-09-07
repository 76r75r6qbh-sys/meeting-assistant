import AVFoundation
import Foundation
import SwiftData
import WhisperKit

private typealias WhisperPipeline = WhisperKit

/// The pieces of one WhisperKit run that `performTranscription` consumes.
///
/// WhisperKit's own `TranscriptionResult` cannot be named inside this module:
/// Casablanca declares a `TranscriptionResult` of its own, which wins
/// unqualified lookup, and `WhisperKit.TranscriptionResult` resolves against
/// the *class* `WhisperKit` rather than the module. So each decode path maps
/// its results into this and everything downstream works off it.
private struct WhisperRun {
    /// WhisperKit's segments, for the transcript and the timing report.
    let segments: [TranscriptionSegment]
    /// One text per result, cleaned and joined into the transcript.
    let texts: [String]
    let chunkTimings: [TranscriptionTimings]
}

/// Transcription segment with timestamp
struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    var formattedTimestamp: String {
        let start = Self.formatTime(startTime)
        return "[\(start)]"
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Result of a transcription operation
struct TranscriptionResult {
    let segments: [TranscriptSegment]
    let fullText: String
    let duration: TimeInterval

    var formattedTranscript: String {
        segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
    }
}

enum TranscriptionError: LocalizedError {
    case fileNotFound(String)
    case invalidAudioFormat
    case transcriptionFailed(String)
    case modelNotAvailable(String)
    case cancelled
    /// A start was refused because a different meeting is mid-transcription.
    /// Refusing silently would leave the refused meeting stuck on `.processing`
    /// with a progress bar for a run that does not exist, so this is surfaced.
    case anotherTranscriptionInProgress(meetingTitle: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Audio file not found at \(path)"
        case .invalidAudioFormat:
            return "The audio file could not be prepared for transcription."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .modelNotAvailable(let model):
            return "Whisper model '\(model)' is not available. It may still be downloading."
        case .cancelled:
            return "Transcription was cancelled."
        case .anotherTranscriptionInProgress(let meetingTitle):
            return "Another meeting (\(meetingTitle)) is still being transcribed. Try again when it finishes."
        }
    }
}

/// Local transcription service backed by WhisperKit.
@MainActor
@Observable
final class TranscriptionService {
    struct WhisperModelOption: Identifiable {
        let id: String
        let name: String
    }

    var isTranscribing = false
    var progress: Double = 0
    var statusMessage = ""
    var currentSegments: [TranscriptSegment] = []

    /// Where the last finished run's time went. Logged as one line when the run
    /// ends; kept so anything that later wants to show or compare runs can.
    private(set) var lastTimingReport: TranscriptionTimingReport?

    /// The meeting whose post-recording pipeline is running (nil when idle).
    /// Unlike `isTranscribing` this stays set for the whole pipeline — including
    /// the export and the AAC re-encode that run after Whisper is done — so a
    /// re-appearing view can tell "still working" from "not started".
    private(set) var transcribingMeetingID: UUID?

    /// The meeting whose pipeline most recently finished cleanly. Views observe
    /// it to learn that *their* meeting is done, which no longer arrives as a
    /// return from the view's own task.
    private(set) var lastCompletedMeetingID: UUID?

    /// What ended the last background run, or nil if it ended cleanly or was
    /// cancelled. The run outlives the view that started it, so the error has to
    /// live here for a view to be able to offer Retry at all.
    private(set) var lastError: TranscriptionError?

    /// Supported transcription languages
    static let supportedLanguages: [(id: String, name: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("nl-NL", "Dutch"),
    ]

    static let availableWhisperModels: [WhisperModelOption] = [
        WhisperModelOption(id: "openai_whisper-tiny", name: "Tiny"),
        WhisperModelOption(id: "openai_whisper-base", name: "Base"),
        WhisperModelOption(id: "openai_whisper-small", name: "Small"),
        WhisperModelOption(id: "openai_whisper-medium", name: "Medium"),
        WhisperModelOption(id: "openai_whisper-large-v3", name: "Large v3"),
    ]

    private static let whisperControlTokenRegex = try! NSRegularExpression(pattern: #"<\|[^|>]+?\|>"#)
    /// Hoisted alongside the control-token pattern: `cleanWhisperText` runs once
    /// per segment (thousands of times for a long meeting) and
    /// `replacingOccurrences(options: .regularExpression)` recompiles the pattern
    /// on every call.
    private static let repeatedWhitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
    private static let whitespaceBeforePunctuationRegex = try! NSRegularExpression(pattern: #"\s+([,.;:!?])"#)

    private var transcriptionTask: Task<TranscriptionResult, Error>?
    /// The service-owned task running `transcribeInBackground`. Deliberately not
    /// tied to any view's lifecycle: navigating away used to cancel the view's
    /// `.task`, which threw out of `transcribe` while the inner unstructured task
    /// kept decoding — and coming back started a SECOND transcription on the same
    /// WhisperKit instance.
    private var backgroundTask: Task<Void, Never>?
    /// Title of the meeting in `transcribingMeetingID`, kept so a refused start
    /// can name what is blocking it without reaching back into the model.
    private var transcribingMeetingTitle = ""
    /// Monotonic id for the run in `backgroundTask`. A cancelled run can still be
    /// unwinding after its replacement has started; the id is how the unwinding
    /// one knows the state it is about to clear is no longer its own.
    private var currentRunID = 0
    /// The last checkpoint we actually know is true (loading floor, a real VAD
    /// segment-discovery update, or completion) — the baseline `progressTicker`
    /// creeps above, so the trickle can never outrun real work by more than
    /// `trickleBudget`.
    private var lastCheckpoint: Double = 0
    private var progressTicker: Task<Void, Never>?
    private static let trickleBudget = 0.04
    private static let trickleCeiling = 0.95
    private static let trickleEasing = 0.25
    /// Accumulates the live transcript across the concurrently decoding chunks.
    /// Reset at the start of every run.
    private var liveSegmentMerger = TranscriptSegmentMerger()
    /// The loaded pipeline and the model *plus* compute units it was built with,
    /// so changing a compute setting reloads instead of reusing a pipeline that
    /// is still on the old units.
    private var pipelineCache = WhisperPipelineCache<WhisperPipeline>()

    /// Transcription is long and unattended: the Mac idle-slept for 37 minutes
    /// in the middle of one. An assertion keeps it awake until the run ends,
    /// however it ends.
    private let sleepPreventer: SleepPreventing
    private static let sleepPreventionReason = "Casablanca is transcribing a meeting"

    /// Keeping the model resident between meetings is a convenience; the system
    /// needing that RAM outranks it, so pressure hands it straight back.
    private let memoryPressureMonitor: MemoryPressureMonitoring

    init(
        sleepPreventer: SleepPreventing = ProcessInfoSleepPreventer(),
        memoryPressureMonitor: MemoryPressureMonitoring = DispatchMemoryPressureMonitor()
    ) {
        self.sleepPreventer = sleepPreventer
        self.memoryPressureMonitor = memoryPressureMonitor
        memoryPressureMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure()
            }
        }
    }

    /// Transcribe `meeting`'s recording and run the whole post-recording
    /// pipeline in a service-owned task that is NOT tied to any view's
    /// lifecycle, so navigating away no longer cancels it — nor leaves a
    /// detached transcription running that a returning view would duplicate.
    ///
    /// Three ways a call can land while something is already in flight:
    /// - the same meeting, genuinely running ⇒ ignored, because the caller's
    ///   view is already showing that run;
    /// - anything, while a cancelled run is only *unwinding* ⇒ the new run waits
    ///   for the predecessor and then starts, so Retry-straight-after-Cancel
    ///   works (one WhisperKit instance, so the two must not overlap);
    /// - a DIFFERENT meeting while one genuinely runs ⇒ refused, and the refusal
    ///   is surfaced as `lastError`. Callers flip the meeting to `.processing`
    ///   before calling (NotesEditorView after Stop, ContentView's "Transcribe"),
    ///   so a silent refusal would leave it spinning on a run that never exists.
    ///   Queueing would need a queue no caller in the app has a use for.
    func transcribeInBackground(
        meeting: Meeting,
        modelContext: ModelContext,
        terminologyService: TerminologyService,
        exportReporter: ExportStatusCenter?
    ) {
        // A cancelled predecessor is not competing for the model, it is leaving;
        // the new run below waits it out rather than being refused.
        let windingDownPredecessor = isWindingDown ? backgroundTask : nil

        if let runningID = transcribingMeetingID, windingDownPredecessor == nil {
            if runningID == meeting.id {
                Log.transcription.notice("second run ignored: this meeting is already transcribing")
            } else {
                Log.transcription.notice("second run ignored: another meeting is transcribing")
                lastError = .anotherTranscriptionInProgress(meetingTitle: transcribingMeetingTitle)
            }
            return
        }

        guard let recordingPath = meeting.recordingFileURL else {
            lastError = .fileNotFound("No recording file available")
            return
        }
        let fileURL = URL(fileURLWithPath: recordingPath)

        // Marked busy synchronously so a near-simultaneous re-trigger (a view
        // re-appearing) hits the guard above before the task even starts.
        transcribingMeetingID = meeting.id
        transcribingMeetingTitle = meeting.title
        lastError = nil
        // Cleared so a re-transcription of the SAME meeting is still a change an
        // observer can see when it finishes.
        lastCompletedMeetingID = nil
        meeting.status = .processing
        try? modelContext.save()

        let pipeline = makePipeline(terminologyService: terminologyService, exportReporter: exportReporter)
        let localeIdentifier = meeting.transcriptionLanguage
        let meetingID = meeting.id
        // Identifies THIS run, so a predecessor unwinding after this one started
        // cannot clear the state belonging to this one.
        currentRunID += 1
        let runID = currentRunID

        backgroundTask = Task { @MainActor in
            defer {
                if self.currentRunID == runID {
                    self.transcribingMeetingID = nil
                }
            }
            if let windingDownPredecessor {
                await windingDownPredecessor.value
            }
            do {
                let result = try await self.runTranscription(
                    fileURL: fileURL,
                    localeIdentifier: localeIdentifier
                )
                try Task.checkCancellation()
                await pipeline.run(
                    meeting: meeting,
                    result: result,
                    recordingURL: fileURL,
                    modelContext: modelContext
                )
                self.lastCompletedMeetingID = meetingID
            } catch {
                // Cancellation is user intent, not a failure — never surface it.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.lastError = (error as? TranscriptionError)
                    ?? .transcriptionFailed(error.localizedDescription)
            }
        }
    }

    /// True while the run in `backgroundTask` has been cancelled and is only
    /// finishing its unwind — it is on its way out, not competing.
    private var isWindingDown: Bool {
        transcribingMeetingID != nil && backgroundTask?.isCancelled == true
    }

    /// The pipeline `transcribeInBackground` runs. A DEBUG seam so the tests can
    /// substitute fakes: the live one writes into Application Support, exports to
    /// the user's real vault and can call an LLM, none of which belongs in a test.
    private func makePipeline(
        terminologyService: TerminologyService,
        exportReporter: ExportStatusCenter?
    ) -> PostTranscriptionPipeline {
#if DEBUG
        if let pipelineOverrideForTesting {
            return pipelineOverrideForTesting
        }
#endif
        return PostTranscriptionPipeline.live(
            terminologyService: terminologyService,
            exportReporter: exportReporter
        )
    }

    /// Dismisses the error a failed background run left behind, so a view's
    /// alert can be closed (and the run retried).
    func clearError() {
        lastError = nil
    }

    /// The transcription step of `transcribeInBackground`, isolated so the tests
    /// can replace it — a real `WhisperKit` needs a downloaded model.
    private func runTranscription(fileURL: URL, localeIdentifier: String) async throws -> TranscriptionResult {
#if DEBUG
        if let transcribeOverrideForTesting {
            return try await transcribeOverrideForTesting(fileURL, localeIdentifier)
        }
#endif
        return try await transcribe(fileURL: fileURL, localeIdentifier: localeIdentifier)
    }

    /// Transcribe an audio file at the given URL
    func transcribe(fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionError.fileNotFound(fileURL.path)
        }

        let sleepAssertion = sleepPreventer.begin(reason: Self.sleepPreventionReason)
        Log.transcription.notice(
            "Holding an idle-sleep assertion: \(Self.sleepPreventionReason, privacy: .public)"
        )

        isTranscribing = true
        progress = 0
        lastCheckpoint = 0
        statusMessage = "Preparing audio file..."
        currentSegments = []
        startProgressTicker()

        defer {
            isTranscribing = false
            stopProgressTicker()
            sleepAssertion.end()
            Log.transcription.notice(
                "Released the idle-sleep assertion: \(Self.sleepPreventionReason, privacy: .public)"
            )
        }

        let locale = localeIdentifier
        let task = Task<TranscriptionResult, Error> {
            try await performTranscription(fileURL: fileURL, localeIdentifier: locale)
        }
        transcriptionTask = task

        let result = try await task.value
        applyRetentionPolicy()
        return result
    }

    /// Releases the cached Whisper model so its memory returns to the OS.
    /// The next transcription reloads it on demand.
    ///
    /// The key goes with the pipeline: a surviving key would make the next load
    /// hand back a pipeline that is no longer there.
    func unloadModel() {
        pipelineCache.clear()
    }

    /// Frees or keeps the just-used model according to what the configured
    /// summarizer needs, and says which it did — this is the difference between
    /// a warm second meeting and re-paying model load plus prewarm.
    private func applyRetentionPolicy() {
        let provider = AppPreferences.llmProvider()
        guard WhisperModelRetentionPolicy.shouldUnloadAfterTranscription(provider: provider) else {
            Log.transcription.notice(
                "keeping the Whisper model loaded: \(provider.rawValue, privacy: .public) needs no local model memory"
            )
            return
        }
        unloadModel()
        Log.transcription.notice(
            "unloaded the Whisper model: \(provider.rawValue, privacy: .public) summarizes locally and needs the memory"
        )
    }

    /// The system is short on memory. A model kept warm for the next meeting is
    /// expendable; one a run is currently decoding with is not — pulling it out
    /// mid-transcription would fail that run.
    func handleMemoryPressure() {
        guard !pipelineCache.isEmpty else { return }
        guard !isTranscribing else {
            Log.transcription.notice(
                "memory pressure while transcribing: keeping the Whisper model until the run ends"
            )
            return
        }
        unloadModel()
        Log.transcription.notice("memory pressure: unloaded the idle Whisper model")
    }

    func cancel() {
        // Both, in this order: the background task owns the pipeline, the inner
        // task owns the decode. Cancelling only the outer one would leave the
        // decode running detached — the bug this whole seam exists to fix.
        backgroundTask?.cancel()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        statusMessage = "Cancelled"
        Log.transcription.notice("transcription cancelled")
    }

    // MARK: - Test Seams

#if DEBUG
    /// A `WhisperKit` cannot be built without loading a real model, so tests
    /// drive the service's teardown paths through a key-only cache; that the
    /// pipeline goes with the key is proven against `WhisperPipelineCache`.
    var cachedPipelineKeyForTesting: WhisperPipelineKey? { pipelineCache.key }
    var cacheIsEmptyForTesting: Bool { pipelineCache.isEmpty }

    func primeCachedPipelineKeyForTesting(_ key: WhisperPipelineKey) {
        pipelineCache.key = key
    }

    /// Replaces the WhisperKit run inside `transcribeInBackground`, so the tests
    /// can exercise the ownership behaviour around it (no-op re-trigger, cancel,
    /// the pipeline) without a downloaded model.
    var transcribeOverrideForTesting: (@MainActor (URL, String) async throws -> TranscriptionResult)?

    /// Replaces the post-transcription pipeline in `transcribeInBackground`, so
    /// no test ever runs the live one — it reads `UserDefaults.standard`, writes
    /// into the real Application Support, exports into the user's real vault and
    /// can make a billed LLM call.
    var pipelineOverrideForTesting: PostTranscriptionPipeline?

    /// Lets a test await the service-owned background run instead of polling.
    func waitForBackgroundWorkForTesting() async {
        await backgroundTask?.value
    }
#endif

    // MARK: - Whisper Implementation

    private func performTranscription(fileURL: URL, localeIdentifier: String) async throws -> TranscriptionResult {
        let asset = AVURLAsset(url: fileURL)
        let duration: TimeInterval
        if #available(macOS 15, *) {
            duration = try await asset.load(.duration).seconds
        } else {
            duration = asset.duration.seconds
        }

        guard duration > 0 else {
            throw TranscriptionError.invalidAudioFormat
        }

        await updateStatus("Preparing local Whisper model...", progress: 0.05)

        let resolved = TranscriptionOptionsBuilder.resolve(
            language: Self.whisperLanguageCode(for: localeIdentifier)
        )

        let modelLoadStart = ContinuousClock.now
        let whisperKit = try await loadWhisperKit(compute: resolved.compute)
        let modelLoadWall = ContinuousClock.now - modelLoadStart

        liveSegmentMerger = TranscriptSegmentMerger()
        whisperKit.segmentDiscoveryCallback = { [weak self] segments in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // WhisperKit reports one 30 s decode window at a time and offsets
                // `seek` by the VAD chunk's start, so the first segment's seek
                // identifies this window across the chunks decoding concurrently.
                // No segments means no window to attribute the report to.
                guard let chunkKey = segments.first?.seek else { return }
                // The report's `start`/`end` are relative to its own window, so
                // shift the whole window onto the absolute clock — otherwise the
                // live list restarts at [00:00] for every chunk.
                let reportMinStart = segments.map { TimeInterval($0.start) }.min() ?? 0
                let mappedSegments = segments
                    .compactMap { segment -> TranscriptSegment? in
                        let times = TranscriptSegmentMerger.absoluteLiveTimes(
                            seek: chunkKey,
                            start: TimeInterval(segment.start),
                            end: TimeInterval(segment.end),
                            reportMinStart: reportMinStart
                        )
                        return Self.makeTranscriptSegment(
                            startTime: times.startTime,
                            endTime: times.endTime,
                            rawText: segment.text
                        )
                    }
                self.liveSegmentMerger.merge(chunkSegments: mappedSegments, chunkKey: chunkKey)
                let mergedSegments = self.liveSegmentMerger.orderedSegments
                self.currentSegments = mergedSegments

                let lastTimestamp = mergedSegments.map(\.endTime).max() ?? 0
                let progressValue = min(0.1 + (lastTimestamp / max(duration, 1)) * 0.85, 0.95)
                let clampedProgress = max(progressValue, self.lastCheckpoint)
                self.lastCheckpoint = clampedProgress
                self.progress = clampedProgress
                self.statusMessage = "Transcribing with local Whisper..."
            }
        }

        let transcribeStart = ContinuousClock.now
        let run = try await Self.runWhisper(whisperKit, fileURL: fileURL, resolved: resolved)
        let transcribeWall = ContinuousClock.now - transcribeStart

        try Task.checkCancellation()

        let segments = run.segments
            .compactMap { segment in
                Self.makeTranscriptSegment(
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    rawText: segment.text
                )
            }
        currentSegments = segments
        await updateStatus("Transcription complete", progress: 1.0)

        let fullText = run.texts
            .map(Self.cleanWhisperText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let report = TranscriptionTimingReport(
            audioSeconds: duration,
            modelLoadWall: modelLoadWall,
            transcribeWall: transcribeWall,
            pipelineTimings: whisperKit.currentTimings,
            chunkTimings: run.chunkTimings,
            segments: run.segments
        )
        lastTimingReport = report
        Log.transcription.notice("transcription finished \(report.summaryLine, privacy: .public)")
        Log.transcription.notice("config \(resolved.summaryLine, privacy: .public)")

        return TranscriptionResult(segments: segments, fullText: fullText, duration: duration)
    }

    /// Decodes the recording, either in one WhisperKit call or — when the
    /// silent-chunk filter is on — chunk by chunk with the silence removed.
    ///
    /// `nonisolated static`: it touches none of the service's observable state,
    /// only its arguments, and decoding has no business hopping onto the main
    /// actor — the live-segment callback already hops there by itself.
    private nonisolated static func runWhisper(
        _ whisperKit: WhisperPipeline,
        fileURL: URL,
        resolved: TranscriptionOptionsBuilder.Resolved
    ) async throws -> WhisperRun {
        let keepGoing: TranscriptionCallback = { _ in Task.isCancelled ? false : true }

        // The filter drops chunks, so it needs something to have made them:
        // with `chunking=none` WhisperKit seeks through the file itself and
        // there is nothing to partition.
        guard resolved.dropSilentChunks, resolved.decoding.chunkingStrategy == .vad else {
            if resolved.dropSilentChunks {
                // Say so rather than no-op silently: a benchmark run that set
                // both keys would otherwise be filed as a filter measurement.
                Log.transcription.notice(
                    "whisperDropSilentChunks needs chunking=vad; ignoring it for this run"
                )
            }
            let results = try await whisperKit.transcribe(
                audioPath: fileURL.path,
                decodeOptions: resolved.decoding,
                callback: keepGoing
            )
            return WhisperRun(
                segments: results.flatMap(\.segments),
                texts: results.map(\.text),
                chunkTimings: results.map(\.timings)
            )
        }

        // This is WhisperKit's own `.vad` branch (`transcribe(audioArray:)`)
        // with the filter spliced between chunking and decoding: load, chunk,
        // drop the chunks that hold no speech, decode what is left, then put
        // the survivors back on the meeting's clock.
        let audioArray = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: fileURL.path,
            channelMode: whisperKit.audioInputConfig.channelMode
        )
        // One VAD instance for both jobs: the chunker splits on the silences it
        // finds, and the filter then judges the chunks by the same threshold.
        let vad = EnergyVAD(energyThreshold: resolved.silentChunkEnergyThreshold)
        let chunker = VADAudioChunker(vad: vad)
        let chunks = try await chunker.chunkAll(
            audioArray: audioArray,
            // 480_000 samples — one 30 s decode window at 16 kHz.
            maxChunkLength: whisperKit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples,
            decodeOptions: resolved.decoding
        )
        let outcome = SilentChunkFilter.partition(chunks, vad: vad)
        let dropped = String(
            format: "dropped=%d chunks / %.1f s of %d chunks",
            outcome.droppedCount,
            outcome.droppedSeconds,
            chunks.count
        )
        Log.transcription.notice("silent-chunk filter \(dropped, privacy: .public)")

        // Every kept chunk is at most one window, so it decodes in a single
        // pass: no second round of chunking, and `chunkAll` has already applied
        // the seek clips, so leaving them in would clip each chunk again.
        var chunkOptions = resolved.decoding
        chunkOptions.chunkingStrategy = ChunkingStrategy.none
        chunkOptions.clipTimestamps = []

        let chunkedResults = await whisperKit.transcribeWithOptions(
            audioArrays: outcome.kept.map(\.audioSamples),
            decodeOptionsArray: Array(repeating: chunkOptions, count: outcome.kept.count),
            seekOffsets: outcome.kept.map(\.seekOffsetIndex),
            callback: keepGoing
        )
        let results = chunker.updateSeekOffsetsForResults(
            chunkedResults: chunkedResults,
            audioChunks: outcome.kept
        )
        return WhisperRun(
            segments: results.flatMap(\.segments),
            texts: results.map(\.text),
            chunkTimings: results.map(\.timings)
        )
    }

    private func loadWhisperKit(compute: ModelComputeOptions) async throws -> WhisperPipeline {
        let selectedModel = UserDefaults.standard.string(forKey: AppPreferenceKey.whisperModel)
            ?? AppPreferenceValue.defaultWhisperModel
        let pipelineKey = WhisperPipelineKey(model: selectedModel, compute: compute)

        if let cached = pipelineCache.pipeline(matching: pipelineKey) {
            return cached
        }

        // A model or compute change means the cached pipeline is unusable — and
        // since it is now kept resident between meetings, building the
        // replacement first would hold both models at once (two large-v3
        // pipelines is several GB). Release it before paying for the new one.
        if let staleKey = pipelineCache.key {
            Log.transcription.notice(
                "Unloading cached Whisper pipeline \(staleKey.summary, privacy: .public) before loading \(pipelineKey.summary, privacy: .public)"
            )
            unloadModel()
        }

        do {
            let pipeline = try await WhisperPipeline(
                WhisperKitConfig(
                    model: selectedModel,
                    downloadBase: try Self.whisperDownloadBaseURL(),
                    computeOptions: compute,
                    verbose: false,
                    logLevel: .none,
                    // Runs a warm-up inference during model load (compiling/caching
                    // the CoreML graph) instead of letting that cost land on the
                    // FIRST real transcription chunk — previously that made the
                    // progress bar look frozen partway through transcribing
                    // (e.g. stuck at ~12%) when it was actually still compiling.
                    prewarm: true,
                    load: true,
                    download: true
                )
            )
            pipeline.modelStateCallback = { [weak self] _, newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch newState {
                    case .downloading:
                        self.statusMessage = "Downloading local Whisper model..."
                    case .downloaded:
                        self.statusMessage = "Local Whisper model downloaded. Loading..."
                    case .loading, .prewarming:
                        self.statusMessage = "Loading local Whisper model..."
                    case .loaded, .prewarmed:
                        if self.statusMessage.isEmpty || self.progress < 0.1 {
                            self.statusMessage = "Local Whisper model ready."
                        }
                    default:
                        break
                    }
                }
            }
            self.pipelineCache.store(pipeline: pipeline, key: pipelineKey)
            return pipeline
        } catch {
            throw TranscriptionError.modelNotAvailable(error.localizedDescription)
        }
    }

    private func updateStatus(_ message: String, progress: Double) async {
        self.statusMessage = message
        self.progress = progress
        self.lastCheckpoint = progress
    }

    /// Starts a lightweight periodic nudge so the bar visibly creeps during the
    /// long, checkpoint-free waits (model loading, a slow single VAD chunk)
    /// instead of sitting dead-still. Cancelled in `transcribe()`'s `defer`.
    private func startProgressTicker() {
        progressTicker?.cancel()
        progressTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await self?.trickleProgress()
            }
        }
    }

    private func stopProgressTicker() {
        progressTicker?.cancel()
        progressTicker = nil
    }

    private func trickleProgress() {
        guard progress > 0 else { return }
        progress = ProgressTrickle.next(
            current: progress,
            checkpoint: lastCheckpoint,
            budget: Self.trickleBudget,
            ceiling: Self.trickleCeiling,
            easing: Self.trickleEasing
        )
    }

    private static func whisperLanguageCode(for localeIdentifier: String) -> String {
        let locale = Locale(identifier: localeIdentifier)
        if #available(macOS 14, *) {
            if let languageCode = locale.language.languageCode?.identifier {
                return languageCode
            }
        }
        return localeIdentifier.split(separator: "-").first.map(String.init) ?? "en"
    }

    private static func cleanWhisperText(_ text: String) -> String {
        let nsRange = NSRange(text.startIndex..., in: text)
        let withoutControlTokens = whisperControlTokenRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: nsRange,
            withTemplate: " "
        )

        let collapsedWhitespace = repeatedWhitespaceRegex.stringByReplacingMatches(
            in: withoutControlTokens,
            options: [],
            range: NSRange(withoutControlTokens.startIndex..., in: withoutControlTokens),
            withTemplate: " "
        )
        let withoutExtraWhitespace = whitespaceBeforePunctuationRegex.stringByReplacingMatches(
            in: collapsedWhitespace,
            options: [],
            range: NSRange(collapsedWhitespace.startIndex..., in: collapsedWhitespace),
            withTemplate: "$1"
        )

        return withoutExtraWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeTranscriptSegment(startTime: TimeInterval, endTime: TimeInterval, rawText: String) -> TranscriptSegment? {
        let cleanedText = cleanWhisperText(rawText)
        guard !cleanedText.isEmpty else {
            return nil
        }

        return TranscriptSegment(
            startTime: startTime,
            endTime: endTime,
            text: cleanedText
        )
    }

    private static func whisperDownloadBaseURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDirectory = appSupport.appendingPathComponent("Casablanca/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        return modelsDirectory
    }

    // MARK: - Transcription File Storage

    /// Save transcript to a local file in Application Support
    static func saveTranscriptLocally(meeting: Meeting, result: TranscriptionResult) throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let transcriptsDir = appSupport.appendingPathComponent("Casablanca/Transcriptions", isDirectory: true)

        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        let fileName = "\(meeting.obsidianFileName).txt"
        let fileURL = transcriptsDir.appendingPathComponent(fileName)

        let content = transcriptFileContents(
            title: meeting.title,
            date: meeting.formattedTime,
            duration: meeting.recordingDuration,
            result: result
        )

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// The transcript file body: a header, a blank line, then one
    /// `[mm:ss] text` line per segment.
    ///
    /// Extracted from `saveTranscriptLocally` so the benchmark harness can write
    /// byte-identical transcripts — a benchmark run has no `Meeting` behind it,
    /// but its output has to be diffable against a saved reference transcript.
    /// `nonisolated`: pure string formatting, so it is callable from anywhere —
    /// the service itself is `@MainActor` only because of its observable state.
    nonisolated static func transcriptFileContents(
        title: String,
        date: String,
        duration: TimeInterval?,
        result: TranscriptionResult
    ) -> String {
        var content = "Transcription: \(title)\n"
        content += "Date: \(date)\n"
        if let duration {
            let minutes = Int(duration / 60)
            let seconds = Int(duration) % 60
            content += "Duration: \(minutes)m \(seconds)s\n"
        }
        content += "---\n\n"
        content += result.formattedTranscript
        return content
    }
}
