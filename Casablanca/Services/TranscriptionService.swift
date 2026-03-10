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

    private var transcriptionTask: Task<TranscriptionResult, Error>?
    private var highWaterProgress: Double = 0
    private var whisperKit: WhisperPipeline?
    private var loadedWhisperModelID: String?

    /// Transcribe an audio file at the given URL
    func transcribe(fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionError.fileNotFound(fileURL.path)
        }

        isTranscribing = true
        progress = 0
        highWaterProgress = 0
        statusMessage = "Preparing audio file..."
        currentSegments = []

        defer {
            isTranscribing = false
        }

        let locale = localeIdentifier
        let task = Task<TranscriptionResult, Error> {
            try await performTranscription(fileURL: fileURL, localeIdentifier: locale)
        }
        transcriptionTask = task

        return try await task.value
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

        let whisperKit = try await loadWhisperKit()
        whisperKit.segmentDiscoveryCallback = { [weak self] segments in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let mappedSegments = segments
                    .compactMap { segment in
                        Self.makeTranscriptSegment(
                            startTime: TimeInterval(segment.start),
                            endTime: TimeInterval(segment.end),
                            rawText: segment.text
                        )
                    }
                self.currentSegments = mappedSegments

                let lastTimestamp = mappedSegments.last?.endTime ?? 0
                let progressValue = min(0.1 + (lastTimestamp / max(duration, 1)) * 0.85, 0.95)
                let clampedProgress = max(progressValue, self.highWaterProgress)
                self.highWaterProgress = clampedProgress
                self.progress = clampedProgress
                self.statusMessage = "Transcribing with local Whisper..."
            }
        }

        let decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: Self.whisperLanguageCode(for: localeIdentifier),
            temperature: 0,
            withoutTimestamps: false,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )

        let results = try await whisperKit.transcribe(
            audioPath: fileURL.path,
            decodeOptions: decodeOptions,
            callback: { _ in
                Task.isCancelled ? false : true
            }
        )

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
        return TranscriptionResult(segments: segments, fullText: fullText, duration: duration)
    }

    private func loadWhisperKit() async throws -> WhisperPipeline {
        let selectedModel = UserDefaults.standard.string(forKey: AppPreferenceKey.whisperModel)
            ?? AppPreferenceValue.defaultWhisperModel

        if let whisperKit, loadedWhisperModelID == selectedModel {
            return whisperKit
        }

        do {
            let pipeline = try await WhisperPipeline(
                WhisperKitConfig(
                    model: selectedModel,
                    downloadBase: try Self.whisperDownloadBaseURL(),
                    verbose: false,
                    logLevel: .none,
                    prewarm: false,
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
            self.loadedWhisperModelID = selectedModel
            return pipeline
        } catch {
            throw TranscriptionError.modelNotAvailable(error.localizedDescription)
        }
    }

    private func updateStatus(_ message: String, progress: Double) async {
        self.statusMessage = message
        self.progress = progress
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

        let withoutExtraWhitespace = withoutControlTokens
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)

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

        var content = "Transcription: \(meeting.title)\n"
        content += "Date: \(meeting.formattedTime)\n"
        if let duration = meeting.recordingDuration {
            let minutes = Int(duration / 60)
            let seconds = Int(duration) % 60
            content += "Duration: \(minutes)m \(seconds)s\n"
        }
        content += "---\n\n"
        content += result.formattedTranscript

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
