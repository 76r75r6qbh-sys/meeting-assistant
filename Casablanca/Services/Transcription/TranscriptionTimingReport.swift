import Foundation
import WhisperKit

extension Duration {
    /// This duration expressed in seconds, for timing logs and timing reports.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// Where one transcription run's time actually went.
///
/// A 90-minute meeting takes 25–30 minutes to transcribe, and WhisperKit's own
/// `TranscriptionTimings` were never read, so nobody could say which phase was
/// responsible. This report combines the app's wall clocks, WhisperKit's
/// pipeline-level timings (`whisperKit.currentTimings`), and everything the
/// results carry — each VAD chunk is its own `TranscribeTask`, so its timings
/// only mean anything summed — into a single log line, so any later
/// optimisation can be measured instead of guessed at.
struct TranscriptionTimingReport: Codable, Sendable {
    /// Length of the audio that was transcribed.
    let audioSeconds: TimeInterval
    /// App-side wall clock around `loadWhisperKit()` (download, load, prewarm).
    let modelLoadWall: TimeInterval
    /// App-side wall clock around `whisperKit.transcribe(...)`.
    let transcribeWall: TimeInterval

    // MARK: - Pipeline timings (whisperKit.currentTimings)

    /// WhisperKit's own measurement of loading the models, prewarm included.
    let modelLoading: TimeInterval
    /// The warm-up inference run during model load.
    let prewarmLoadTime: TimeInterval
    /// CoreML specialization of the encoder and decoder combined — the on-device
    /// graph compile that only happens on a cold model.
    let specializationTime: TimeInterval
    /// Reading and resampling the audio file to 16kHz float samples.
    let audioLoading: TimeInterval

    // MARK: - Decode timings, summed over results.map(\.timings)

    let logmels: TimeInterval
    let encoding: TimeInterval
    let decodingLoop: TimeInterval
    let decodingPredictions: TimeInterval
    let decodingKvCaching: TimeInterval
    let decodingFallback: TimeInterval
    /// WhisperKit's own summed `totalDecodingWindows`. Reported for comparison
    /// only — it is a different population from `totalWindows` and must not be
    /// used as the denominator for `fallbackWindows`.
    let whisperDecodingWindows: Int
    /// Total tokens decoded across all chunks (one per decoding loop).
    let totalTokens: Int

    // MARK: - Fallbacks, derived from the result segments

    /// Decode windows the results actually describe: one per distinct
    /// `TranscriptionSegment.seek`. The denominator for `fallbackWindows`.
    let totalWindows: Int
    /// How many decode windows (the value) ended at exactly that many
    /// temperature fallbacks (the key); key `0` means decoded first try.
    let fallbackHistogram: [Int: Int]

    /// WhisperKit retries a window at `temperature + 0.2` per fallback
    /// (`DecodingOptions.temperatureIncrementOnFallback`), so the highest
    /// temperature a window reached, divided by that step, is its fallback count.
    private static let temperatureIncrementOnFallback: Float = 0.2

    /// - Parameters:
    ///   - pipelineTimings: `whisperKit.currentTimings` after the run.
    ///   - chunkTimings: `results.map(\.timings)` — one entry per VAD chunk.
    ///   - segments: `results.flatMap(\.segments)`. Both `fallbackWindows` and
    ///     `totalWindows` are derived from these same segments, so the ratio
    ///     can never end up describing two different populations.
    init(
        audioSeconds: TimeInterval,
        modelLoadWall: Duration,
        transcribeWall: Duration,
        pipelineTimings: TranscriptionTimings,
        chunkTimings: [TranscriptionTimings],
        segments: [TranscriptionSegment]
    ) {
        self.audioSeconds = audioSeconds
        self.modelLoadWall = modelLoadWall.timeInterval
        self.transcribeWall = transcribeWall.timeInterval

        self.modelLoading = pipelineTimings.modelLoading
        self.prewarmLoadTime = pipelineTimings.prewarmLoadTime
        self.specializationTime = pipelineTimings.encoderSpecializationTime
            + pipelineTimings.decoderSpecializationTime
        self.audioLoading = pipelineTimings.audioLoading

        self.logmels = chunkTimings.reduce(0) { $0 + $1.logmels }
        self.encoding = chunkTimings.reduce(0) { $0 + $1.encoding }
        self.decodingLoop = chunkTimings.reduce(0) { $0 + $1.decodingLoop }
        self.decodingPredictions = chunkTimings.reduce(0) { $0 + $1.decodingPredictions }
        self.decodingKvCaching = chunkTimings.reduce(0) { $0 + $1.decodingKvCaching }
        self.decodingFallback = chunkTimings.reduce(0) { $0 + $1.decodingFallback }
        self.whisperDecodingWindows = Int(chunkTimings.reduce(0) { $0 + $1.totalDecodingWindows })
        self.totalTokens = Int(chunkTimings.reduce(0) { $0 + $1.totalDecodingLoops })

        let maxTemperatureByWindow = Self.maxTemperatureByWindow(segments: segments)
        self.totalWindows = maxTemperatureByWindow.count
        self.fallbackHistogram = Self.fallbackHistogram(
            maxTemperatureByWindow: maxTemperatureByWindow
        )
    }

    /// Whole-run wall clock: loading the model plus transcribing.
    var totalWall: TimeInterval { modelLoadWall + transcribeWall }

    /// Audio seconds transcribed per second of transcription — the number any
    /// decode optimisation has to move. Excludes model loading, which is a
    /// separate problem with a separate fix.
    var speedFactor: Double { transcribeWall > 0 ? audioSeconds / transcribeWall : 0 }

    /// Decode windows that needed at least one temperature fallback.
    var fallbackWindows: Int {
        fallbackHistogram.filter { $0.key > 0 }.values.reduce(0, +)
    }

    /// The whole report on one line of `key=value` pairs, for `Log.transcription`.
    var summaryLine: String {
        let histogram = fallbackHistogram
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")

        return [
            "audio=\(Self.seconds(audioSeconds))s",
            "wall=\(Self.seconds(transcribeWall))s",
            "speed=\(String(format: "%.2f", speedFactor))x",
            "total=\(Self.seconds(totalWall))s",
            "load=\(Self.seconds(modelLoadWall))s",
            "wkLoad=\(Self.seconds(modelLoading))s",
            "prewarm=\(Self.seconds(prewarmLoadTime))s",
            "spec=\(Self.seconds(specializationTime))s",
            "audioLoad=\(Self.seconds(audioLoading))s",
            "mel=\(Self.seconds(logmels))s",
            "enc=\(Self.seconds(encoding))s",
            "dec=\(Self.seconds(decodingLoop))s",
            "pred=\(Self.seconds(decodingPredictions))s",
            "kv=\(Self.seconds(decodingKvCaching))s",
            "fb=\(Self.seconds(decodingFallback))s",
            "fbWindows=\(fallbackWindows)/\(totalWindows)",
            "wkWindows=\(whisperDecodingWindows)",
            "tokens=\(totalTokens)",
            "fbHist=\(histogram.isEmpty ? "none" : histogram)",
        ].joined(separator: " ")
    }

    /// The temperature each decode window ended up at, keyed by its `seek`.
    ///
    /// `seek` is the window key rather than `TranscriptionProgress.windowId`
    /// for two reasons: the progress callback never carries a temperature at
    /// all (`TranscriptionProgress.temperature` is left nil at its only
    /// construction site in `TextDecoder`), and `windowId` is rewritten per
    /// batch in a way that collides when the last batch is partial. Segment
    /// temperatures come straight from the window's `decodingResult`, and VAD
    /// chunking offsets every segment's `seek` by its chunk's offset into the
    /// recording (`TranscriptionUtilities.updateSegmentTimings`), so a seek
    /// identifies exactly one decode window across the whole file.
    private static func maxTemperatureByWindow(segments: [TranscriptionSegment]) -> [Int: Float] {
        var maxTemperatureByWindow: [Int: Float] = [:]
        for segment in segments {
            let highest = max(
                maxTemperatureByWindow[segment.seek] ?? segment.temperature,
                segment.temperature
            )
            maxTemperatureByWindow[segment.seek] = highest
        }
        return maxTemperatureByWindow
    }

    private static func fallbackHistogram(maxTemperatureByWindow: [Int: Float]) -> [Int: Int] {
        var histogram: [Int: Int] = [:]
        for maxTemperature in maxTemperatureByWindow.values {
            let fallbacks = Int((maxTemperature / temperatureIncrementOnFallback).rounded())
            histogram[fallbacks, default: 0] += 1
        }
        return histogram
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.0f", interval.isFinite ? interval : 0)
    }
}
