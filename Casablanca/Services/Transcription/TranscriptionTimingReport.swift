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
/// pipeline-level timings (`whisperKit.currentTimings`), and the per-chunk
/// decode timings — each VAD chunk is its own `TranscribeTask`, so those only
/// mean anything summed — into a single log line, so any later optimisation can
/// be measured instead of guessed at.
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
    /// Total decoding windows across all chunks.
    let totalWindows: Int
    /// Total tokens decoded across all chunks (one per decoding loop).
    let totalTokens: Int

    /// How many decoding windows (the value) needed exactly that many
    /// temperature fallbacks (the key); key `0` means decoded first try.
    /// Rebuilt from the progress callback because WhisperKit's own
    /// `totalDecodingFallbacks` undercounts by one per window.
    let fallbackHistogram: [Int: Int]

    /// WhisperKit retries a window at `temperature + 0.2` per fallback
    /// (`DecodingOptions.temperatureIncrementOnFallback`), so the highest
    /// temperature a window reached, divided by that step, is its fallback count.
    private static let temperatureIncrementOnFallback: Float = 0.2

    init(
        audioSeconds: TimeInterval,
        modelLoadWall: Duration,
        transcribeWall: Duration,
        pipelineTimings: TranscriptionTimings,
        chunkTimings: [TranscriptionTimings],
        maxTemperatureByWindow: [Int: Float]
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
        self.totalWindows = Int(chunkTimings.reduce(0) { $0 + $1.totalDecodingWindows })
        self.totalTokens = Int(chunkTimings.reduce(0) { $0 + $1.totalDecodingLoops })

        self.fallbackHistogram = Self.fallbackHistogram(maxTemperatureByWindow: maxTemperatureByWindow)
    }

    /// Whole-run wall clock: loading the model plus transcribing.
    var totalWall: TimeInterval { modelLoadWall + transcribeWall }

    /// Audio seconds transcribed per wall-clock second over the whole run.
    var speedFactor: Double { totalWall > 0 ? audioSeconds / totalWall : 0 }

    /// Windows that needed at least one temperature fallback.
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
            "wall=\(Self.seconds(totalWall))s",
            "speed=\(String(format: "%.2f", speedFactor))x",
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
            "tokens=\(totalTokens)",
            "fbHist=\(histogram.isEmpty ? "none" : histogram)",
        ].joined(separator: " ")
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

/// Records the highest decoding temperature each window reached, so the exact
/// fallback histogram can be rebuilt after the run.
///
/// WhisperKit calls the progress callback off the main actor, once per decoded
/// token, so this has to be cheap and safe from any thread: one uncontended
/// lock and one dictionary keyed by `windowId`.
final class WindowTemperatureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var maxTemperatureByWindow: [Int: Float] = [:]

    func record(windowId: Int, temperature: Float) {
        lock.lock()
        defer { lock.unlock() }
        if let seen = maxTemperatureByWindow[windowId], seen >= temperature { return }
        maxTemperatureByWindow[windowId] = temperature
    }

    var snapshot: [Int: Float] {
        lock.lock()
        defer { lock.unlock() }
        return maxTemperatureByWindow
    }
}
