import CoreML
import Foundation
import WhisperKit

/// Identity of a loaded WhisperKit pipeline.
///
/// The pipeline is cached across transcriptions, and the compute units are baked
/// into the CoreML models at load time — so the cache key has to include them.
/// Keyed on the model name alone, flipping `whisperEncoderCompute` would silently
/// reuse a pipeline still running on the previous compute units and make any A/B
/// measurement meaningless.
struct WhisperPipelineKey: Equatable {
    let model: String
    let melCompute: MLComputeUnits
    let audioEncoderCompute: MLComputeUnits
    let textDecoderCompute: MLComputeUnits
    let prefillCompute: MLComputeUnits

    init(model: String, compute: ModelComputeOptions) {
        self.model = model
        self.melCompute = compute.melCompute
        self.audioEncoderCompute = compute.audioEncoderCompute
        self.textDecoderCompute = compute.textDecoderCompute
        self.prefillCompute = compute.prefillCompute
    }
}

/// The one place transcription decides *how* to decode.
///
/// Every knob that affects transcription speed or quality is resolved here, from
/// a default that reproduces the app's current behaviour, optionally overridden
/// by a hidden `UserDefaults` key. `UserDefaults.standard` reads its argument
/// domain first, so a benchmark run can flip any of these from the command line
/// without a rebuild:
///
///     Casablanca.app/Contents/MacOS/Casablanca -whisperWorkers 8 -whisperDecoderCompute gpu
///
/// Nothing surfaces these in Settings on purpose: they exist so decoding and
/// compute settings can be A/B'd against a benchmark, not so users can break
/// their own transcriptions.
struct TranscriptionOptionsBuilder {
    /// Hidden tuning keys. Deliberately *not* in `AppPreferenceKey` — those are
    /// user-facing preferences with UI behind them; these are measurement knobs.
    enum Key {
        static let fallbackCount = "whisperFallbackCount"
        static let workers = "whisperWorkers"
        static let decoderCompute = "whisperDecoderCompute"
        static let encoderCompute = "whisperEncoderCompute"
        static let dropSilentChunks = "whisperDropSilentChunks"
        static let silentChunkEnergy = "whisperSilentChunkEnergy"
        static let logProbThreshold = "whisperLogProbThreshold"
        static let compressionRatioThreshold = "whisperCompressionRatioThreshold"
    }

    // Defaults: exactly what the app did before this seam existed, except
    // `skipSpecialTokens`, which only removes tokens `cleanWhisperText` already
    // strips by regex.
    private static let defaultFallbackCount = 5
    /// WhisperKit's own macOS default (`DecodingOptions.init`), spelled out so a
    /// change on their side shows up as a test failure rather than a silent shift.
    private static let defaultWorkers = 16
    private static let defaultLogProbThreshold: Float = -1.0
    private static let defaultCompressionRatioThreshold: Float = 2.4
    private static let defaultSilentChunkEnergy: Float = 0.02
    private static let defaultMelCompute: MLComputeUnits = .cpuAndGPU
    private static let defaultEncoderCompute: MLComputeUnits = .cpuAndNeuralEngine
    private static let defaultDecoderCompute: MLComputeUnits = .cpuAndNeuralEngine
    private static let defaultPrefillCompute: MLComputeUnits = .cpuOnly

    /// Everything one transcription run needs, plus a one-line description of it
    /// for the log so a timing report can be tied back to the settings that
    /// produced it.
    struct Resolved: Equatable {
        let decoding: DecodingOptions
        let compute: ModelComputeOptions
        /// Whether near-silent chunks should be dropped before decoding. Resolved
        /// here; the filter itself is a later task. While it is unimplemented the
        /// flag only means "don't let WhisperKit chunk by VAD".
        let dropSilentChunks: Bool
        let silentChunkEnergyThreshold: Float
        let summaryLine: String

        /// `DecodingOptions` and `ModelComputeOptions` are neither `Equatable`
        /// upstream, so equality compares exactly the fields this builder sets.
        static func == (lhs: Resolved, rhs: Resolved) -> Bool {
            lhs.dropSilentChunks == rhs.dropSilentChunks
                && lhs.silentChunkEnergyThreshold == rhs.silentChunkEnergyThreshold
                && lhs.summaryLine == rhs.summaryLine
                && lhs.decoding.language == rhs.decoding.language
                && lhs.decoding.task == rhs.decoding.task
                && lhs.decoding.temperature == rhs.decoding.temperature
                && lhs.decoding.temperatureFallbackCount == rhs.decoding.temperatureFallbackCount
                && lhs.decoding.concurrentWorkerCount == rhs.decoding.concurrentWorkerCount
                && lhs.decoding.skipSpecialTokens == rhs.decoding.skipSpecialTokens
                && lhs.decoding.withoutTimestamps == rhs.decoding.withoutTimestamps
                && lhs.decoding.wordTimestamps == rhs.decoding.wordTimestamps
                && lhs.decoding.compressionRatioThreshold == rhs.decoding.compressionRatioThreshold
                && lhs.decoding.logProbThreshold == rhs.decoding.logProbThreshold
                && lhs.decoding.firstTokenLogProbThreshold == rhs.decoding.firstTokenLogProbThreshold
                && lhs.decoding.noSpeechThreshold == rhs.decoding.noSpeechThreshold
                && lhs.decoding.chunkingStrategy == rhs.decoding.chunkingStrategy
                && lhs.compute.melCompute == rhs.compute.melCompute
                && lhs.compute.audioEncoderCompute == rhs.compute.audioEncoderCompute
                && lhs.compute.textDecoderCompute == rhs.compute.textDecoderCompute
                && lhs.compute.prefillCompute == rhs.compute.prefillCompute
        }
    }

    /// - Parameters:
    ///   - language: Whisper language code (`"nl"`, `"en"`), not a locale id.
    ///   - defaults: Where the hidden overrides are read from. Tests inject a
    ///     throwaway suite; the app uses `.standard` so command-line arguments
    ///     are picked up.
    static func resolve(language: String, defaults: UserDefaults = .standard) -> Resolved {
        let compute = ModelComputeOptions(
            melCompute: defaultMelCompute,
            audioEncoderCompute: computeUnits(defaults, Key.encoderCompute, or: defaultEncoderCompute),
            textDecoderCompute: computeUnits(defaults, Key.decoderCompute, or: defaultDecoderCompute),
            prefillCompute: defaultPrefillCompute
        )

        // A negative fallback count is nonsense but harmless once clamped; zero
        // is a legitimate setting ("never retry a window at a higher
        // temperature"), so it must survive the clamp.
        let fallbackCount = max(0, int(defaults, Key.fallbackCount) ?? defaultFallbackCount)
        // Zero or fewer workers would stall the decoder outright, so treat those
        // as "not set" rather than clamping to 1 and pretending it was meant.
        let workers = int(defaults, Key.workers).flatMap { $0 > 0 ? $0 : nil } ?? defaultWorkers

        let dropSilentChunks = defaults.bool(forKey: Key.dropSilentChunks)
        let silentChunkEnergy = float(defaults, Key.silentChunkEnergy) ?? defaultSilentChunkEnergy
        let logProbThreshold = float(defaults, Key.logProbThreshold) ?? defaultLogProbThreshold
        let compressionRatioThreshold = float(defaults, Key.compressionRatioThreshold)
            ?? defaultCompressionRatioThreshold

        // Dropping silent chunks means doing the chunking ourselves, so
        // WhisperKit's own VAD chunking has to be off for that run.
        let chunkingStrategy: ChunkingStrategy? = dropSilentChunks ? nil : .vad

        let decoding = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: fallbackCount,
            // Whisper's control tokens (`<|nospeech|>` and friends) carry no
            // meaning for a meeting transcript and `cleanWhisperText` strips them
            // by regex anyway; asking the tokenizer to skip them is the same
            // result one step earlier.
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            compressionRatioThreshold: compressionRatioThreshold,
            logProbThreshold: logProbThreshold,
            concurrentWorkerCount: workers,
            chunkingStrategy: chunkingStrategy
        )

        let summaryLine = [
            "lang=\(language)",
            "task=\(decoding.task.description)",
            "temp=\(decoding.temperature)",
            "fallbacks=\(decoding.temperatureFallbackCount)",
            "workers=\(decoding.concurrentWorkerCount)",
            "logProb=\(logProbThreshold)",
            "compression=\(compressionRatioThreshold)",
            "firstTokenLogProb=\(describe(decoding.firstTokenLogProbThreshold))",
            "noSpeech=\(describe(decoding.noSpeechThreshold))",
            "chunking=\(decoding.chunkingStrategy?.rawValue ?? "none")",
            "skipSpecialTokens=\(decoding.skipSpecialTokens)",
            "wordTimestamps=\(decoding.wordTimestamps)",
            "withoutTimestamps=\(decoding.withoutTimestamps)",
            "mel=\(name(compute.melCompute))",
            "enc=\(name(compute.audioEncoderCompute))",
            "dec=\(name(compute.textDecoderCompute))",
            "prefill=\(name(compute.prefillCompute))",
            "dropSilent=\(dropSilentChunks)",
            "silentEnergy=\(silentChunkEnergy)",
        ].joined(separator: " ")

        return Resolved(
            decoding: decoding,
            compute: compute,
            dropSilentChunks: dropSilentChunks,
            silentChunkEnergyThreshold: silentChunkEnergy,
            summaryLine: summaryLine
        )
    }

    // MARK: - Reading overrides

    /// `nil` when the key is absent, so a deliberate `0` can be told apart from
    /// "not set" — `UserDefaults.integer(forKey:)` returns `0` for both.
    private static func int(_ defaults: UserDefaults, _ key: String) -> Int? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    private static func float(_ defaults: UserDefaults, _ key: String) -> Float? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.float(forKey: key)
    }

    /// Anything unrecognised falls back to the default rather than failing the
    /// run: a typo in a benchmark argument should cost a comparison, not a
    /// transcription.
    private static func computeUnits(
        _ defaults: UserDefaults,
        _ key: String,
        or fallback: MLComputeUnits
    ) -> MLComputeUnits {
        switch defaults.string(forKey: key)?.lowercased() {
        case "ane": return .cpuAndNeuralEngine
        case "gpu": return .cpuAndGPU
        case "cpu": return .cpuOnly
        default: return fallback
        }
    }

    private static func name(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpu"
        case .cpuAndGPU: return "gpu"
        case .cpuAndNeuralEngine: return "ane"
        case .all: return "all"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ value: Float?) -> String {
        value.map { "\($0)" } ?? "none"
    }
}
