import AVFoundation
import Foundation
import WhisperKit

private typealias WhisperPipeline = WhisperKit

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
    /// The last checkpoint we actually know is true (loading floor, a real VAD
    /// segment-discovery update, or completion) — the baseline `progressTicker`
    /// creeps above, so the trickle can never outrun real work by more than
    /// `trickleBudget`.
    private var lastCheckpoint: Double = 0
    private var progressTicker: Task<Void, Never>?
    private static let trickleBudget = 0.04
    private static let trickleCeiling = 0.95
    private static let trickleEasing = 0.25
    private var whisperKit: WhisperPipeline?
    /// Accumulates the live transcript across the concurrently decoding chunks.
    /// Reset at the start of every run.
    private var liveSegmentMerger = TranscriptSegmentMerger()
    /// The model *and* the compute units the cached pipeline was built with, so
    /// changing a compute setting reloads instead of reusing a pipeline that is
    /// still on the old units.
    private var loadedWhisperPipelineKey: WhisperPipelineKey?

    /// Transcription is long and unattended: the Mac idle-slept for 37 minutes
    /// in the middle of one. An assertion keeps it awake until the run ends,
    /// however it ends.
    private let sleepPreventer: SleepPreventing
    private static let sleepPreventionReason = "Casablanca is transcribing a meeting"

    init(sleepPreventer: SleepPreventing = ProcessInfoSleepPreventer()) {
        self.sleepPreventer = sleepPreventer
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
        // Free the Whisper model from memory now that transcription is done.
        // Summarization usually runs immediately after and a local LLM (oMLX/
        // Ollama) needs several GB free; keeping the Whisper model resident can
        // push the machine over the LLM's memory guard and fail the request.
        unloadModel()
        return result
    }

    /// Releases the cached Whisper model so its memory returns to the OS.
    /// The next transcription reloads it on demand.
    func unloadModel() {
        whisperKit = nil
        loadedWhisperPipelineKey = nil
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        statusMessage = "Cancelled"
    }

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
        // `resolve` turns VAD chunking off when silence is to be dropped, because
        // that filter will do its own chunking. It does not exist yet, so keep
        // VAD chunking on rather than quietly decoding the whole file in one go.
        var decodeOptions = resolved.decoding
        if resolved.dropSilentChunks {
            decodeOptions.chunkingStrategy = .vad
            Log.transcription.notice(
                "whisperDropSilentChunks is set but the silent-chunk filter is not implemented yet; keeping VAD chunking"
            )
        }

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
                let mappedSegments = segments
                    .compactMap { segment in
                        Self.makeTranscriptSegment(
                            startTime: TimeInterval(segment.start),
                            endTime: TimeInterval(segment.end),
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
        let results = try await whisperKit.transcribe(
            audioPath: fileURL.path,
            decodeOptions: decodeOptions,
            callback: { _ in
                Task.isCancelled ? false : true
            }
        )
        let transcribeWall = ContinuousClock.now - transcribeStart

        try Task.checkCancellation()

        let segments = results
            .flatMap(\.segments)
            .compactMap { segment in
                Self.makeTranscriptSegment(
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    rawText: segment.text
                )
            }
        currentSegments = segments
        await updateStatus("Transcription complete", progress: 1.0)

        let fullText = results
            .map(\.text)
            .map(Self.cleanWhisperText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let report = TranscriptionTimingReport(
            audioSeconds: duration,
            modelLoadWall: modelLoadWall,
            transcribeWall: transcribeWall,
            pipelineTimings: whisperKit.currentTimings,
            chunkTimings: results.map(\.timings),
            segments: results.flatMap(\.segments)
        )
        lastTimingReport = report
        Log.transcription.notice("transcription finished \(report.summaryLine, privacy: .public)")
        Log.transcription.notice("config \(resolved.summaryLine, privacy: .public)")

        return TranscriptionResult(segments: segments, fullText: fullText, duration: duration)
    }

    private func loadWhisperKit(compute: ModelComputeOptions) async throws -> WhisperPipeline {
        let selectedModel = UserDefaults.standard.string(forKey: AppPreferenceKey.whisperModel)
            ?? AppPreferenceValue.defaultWhisperModel
        let pipelineKey = WhisperPipelineKey(model: selectedModel, compute: compute)

        if let whisperKit, loadedWhisperPipelineKey == pipelineKey {
            return whisperKit
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
            self.whisperKit = pipeline
            self.loadedWhisperPipelineKey = pipelineKey
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
