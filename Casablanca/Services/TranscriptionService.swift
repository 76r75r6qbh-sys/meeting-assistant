import AVFoundation
import Foundation

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
            return "The audio file format is not supported. Expected WAV 16kHz mono."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .modelNotAvailable(let model):
            return "Whisper model '\(model)' is not available. It may still be downloading."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}

/// Local transcription service using macOS Speech Recognition.
///
/// Uses Apple's on-device speech recognition (SFSpeechRecognizer) which works
/// out of the box on macOS 14+ with no additional downloads. For higher accuracy,
/// WhisperKit can be integrated as a future enhancement.
@MainActor
@Observable
final class TranscriptionService {
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

    private var transcriptionTask: Task<TranscriptionResult, Error>?
    private var highWaterProgress: Double = 0

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

    // MARK: - Speech Recognition Implementation

    private func performTranscription(fileURL: URL, localeIdentifier: String) async throws -> TranscriptionResult {
        await updateStatus("Loading audio file...", progress: 0.05)

        // Get audio duration for progress tracking
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

        let locale = Locale(identifier: localeIdentifier)
        await updateStatus("Starting speech recognition (\(locale.language.languageCode?.identifier ?? localeIdentifier))...", progress: 0.1)

        // Use Apple's SFSpeechRecognizer for on-device transcription
        let segments = try await transcribeWithSpeechFramework(fileURL: fileURL, totalDuration: duration, locale: locale)

        try Task.checkCancellation()

        await updateStatus("Transcription complete", progress: 1.0)

        let fullText = segments.map(\.text).joined(separator: " ")
        return TranscriptionResult(segments: segments, fullText: fullText, duration: duration)
    }

    private func transcribeWithSpeechFramework(fileURL: URL, totalDuration: TimeInterval, locale: Locale) async throws -> [TranscriptSegment] {
        guard NSClassFromString("SFSpeechRecognizer") != nil else {
            throw TranscriptionError.transcriptionFailed("Speech framework not available")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranscriptSegment], Error>) in
            SpeechRecognitionHelper.recognize(
                fileURL: fileURL,
                totalDuration: totalDuration,
                locale: locale,
                onProgress: { [weak self] progress, message, segments in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Monotonically increasing progress — never go backwards
                        let clampedProgress = max(progress, self.highWaterProgress)
                        self.highWaterProgress = clampedProgress
                        self.progress = clampedProgress
                        self.statusMessage = message
                        self.currentSegments = segments
                    }
                },
                completion: { result in
                    switch result {
                    case .success(let segments):
                        continuation.resume(returning: segments)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )
        }
    }

    private func updateStatus(_ message: String, progress: Double) async {
        self.statusMessage = message
        self.progress = progress
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

// MARK: - Speech Recognition Helper

import Speech

/// Helper that wraps SFSpeechRecognizer for audio file transcription
private final class SpeechRecognitionHelper: NSObject {

    static func recognize(
        fileURL: URL,
        totalDuration: TimeInterval,
        locale: Locale,
        onProgress: @escaping (Double, String, [TranscriptSegment]) -> Void,
        completion: @escaping (Result<[TranscriptSegment], Error>) -> Void
    ) {
        // Request authorization
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                completion(.failure(TranscriptionError.transcriptionFailed(
                    "Speech recognition not authorized. Please enable it in System Settings > Privacy & Security > Speech Recognition."
                )))
                return
            }

            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                completion(.failure(TranscriptionError.transcriptionFailed("Speech recognizer not available for \(locale.identifier). Check that the language is installed in System Settings > General > Language & Region.")))
                return
            }

            guard recognizer.isAvailable else {
                completion(.failure(TranscriptionError.transcriptionFailed("Speech recognizer is not currently available")))
                return
            }

            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.shouldReportPartialResults = true
            request.addsPunctuation = true

            // Use on-device if available, otherwise fall back to default
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            var bestSegments: [TranscriptSegment] = []
            var bestMerged: [TranscriptSegment] = []
            var hasCompleted = false

            recognizer.recognitionTask(with: request) { result, error in
                if hasCompleted { return }

                if let result {
                    // Build segments from transcription results
                    let newSegments = result.bestTranscription.segments.map { segment in
                        TranscriptSegment(
                            startTime: segment.timestamp,
                            endTime: segment.timestamp + segment.duration,
                            text: segment.substring
                        )
                    }

                    // Keep the best (most content) segments seen so far —
                    // SFSpeechRecognizer can revise the final result to be empty
                    if newSegments.count >= bestSegments.count {
                        bestSegments = newSegments
                        bestMerged = Self.mergeSegments(bestSegments, maxGap: 1.5, maxLength: 200)
                    }

                    // Report progress based on how far into the audio we are
                    let lastTimestamp = result.bestTranscription.segments.last?.timestamp ?? 0
                    let progressValue = min(0.1 + (lastTimestamp / max(totalDuration, 1)) * 0.85, 0.95)
                    let progressPercent = Int(progressValue * 100)
                    onProgress(progressValue, "Transcribing... \(progressPercent)%", bestMerged)

                    if result.isFinal {
                        hasCompleted = true
                        onProgress(0.98, "Finalizing transcript...", bestMerged)
                        completion(.success(bestMerged))
                    }
                }

                if let error, !hasCompleted {
                    hasCompleted = true
                    // SFSpeechRecognizer often fires an error after partial results
                    // without ever setting isFinal. Return best segments we collected.
                    if !bestMerged.isEmpty {
                        onProgress(0.98, "Finalizing transcript...", bestMerged)
                        completion(.success(bestMerged))
                    } else {
                        completion(.failure(TranscriptionError.transcriptionFailed(error.localizedDescription)))
                    }
                }
            }
        }
    }

    /// Merge very short consecutive segments into longer sentence-like chunks
    private static func mergeSegments(_ segments: [TranscriptSegment], maxGap: TimeInterval, maxLength: Int) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        var currentStart = segments[0].startTime
        var currentEnd = segments[0].endTime
        var currentText = segments[0].text

        for i in 1..<segments.count {
            let segment = segments[i]
            let gap = segment.startTime - currentEnd
            let wouldBeTooLong = (currentText.count + segment.text.count + 1) > maxLength

            if gap > maxGap || wouldBeTooLong {
                // Finish current merged segment
                merged.append(TranscriptSegment(
                    startTime: currentStart,
                    endTime: currentEnd,
                    text: currentText.trimmingCharacters(in: .whitespaces)
                ))
                currentStart = segment.startTime
                currentEnd = segment.endTime
                currentText = segment.text
            } else {
                // Merge into current
                currentEnd = segment.endTime
                currentText += " " + segment.text
            }
        }

        // Don't forget the last segment
        merged.append(TranscriptSegment(
            startTime: currentStart,
            endTime: currentEnd,
            text: currentText.trimmingCharacters(in: .whitespaces)
        ))

        return merged
    }
}
