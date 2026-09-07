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

    /// Compact identity for log lines, including the compute units so a
    /// compute-only change is still distinguishable from a no-op.
    var summary: String {
        "\(model) mel=\(melCompute.rawValue) enc=\(audioEncoderCompute.rawValue)"
            + " dec=\(textDecoderCompute.rawValue) prefill=\(prefillCompute.rawValue)"
    }
}

/// The one cached Whisper pipeline, together with the key it was built with.
///
/// One value type rather than two fields on the service, because the two must
/// disappear together: a surviving key makes the next load hand back a pipeline
/// that has been released, and a surviving pipeline is gigabytes nobody asked
/// for. `clear()` is the single place that tears both down.
///
/// Generic over the pipeline so it can be exercised without a real `WhisperKit`,
/// which cannot be constructed without downloading and loading a model.
struct WhisperPipelineCache<Pipeline> {
    var pipeline: Pipeline?
    var key: WhisperPipelineKey?

    var isLoaded: Bool { pipeline != nil }
    var isEmpty: Bool { pipeline == nil && key == nil }

    /// The cached pipeline, but only if it was built with `key` — the compute
    /// units are baked in at load time, so anything else has to be reloaded.
    func pipeline(matching key: WhisperPipelineKey) -> Pipeline? {
        self.key == key ? pipeline : nil
    }

    mutating func store(pipeline: Pipeline, key: WhisperPipelineKey) {
        self.pipeline = pipeline
        self.key = key
    }

    mutating func clear() {
        pipeline = nil
        key = nil
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
        static let chunking = "whisperChunking"
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
    private static let defaultDropSilentChunks = false
    private static let defaultChunking: ChunkingStrategy = .vad
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
        /// Whether near-silent chunks should be dropped before decoding.
        /// Independent of the chunking strategy, but only meaningful with
        /// `.vad`: the filter throws away chunks, so something has to make them.
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

        let dropSilentChunks = bool(defaults, Key.dropSilentChunks, or: defaultDropSilentChunks)
        // A threshold of zero marks every frame voiced and a negative one is
        // arithmetically meaningless against an RMS energy, so neither is a
        // setting anyone means — treat both as "not set".
        let silentChunkEnergy = float(defaults, Key.silentChunkEnergy)
            .flatMap { $0 > 0 ? $0 : nil } ?? defaultSilentChunkEnergy
        let logProbThreshold = float(defaults, Key.logProbThreshold) ?? defaultLogProbThreshold
        let compressionRatioThreshold = float(defaults, Key.compressionRatioThreshold)
            ?? defaultCompressionRatioThreshold

        // `.vad` splits every window at a silence in its second half, so chunks
        // average ~21 s and each is padded back to 30 s — 44 % of the decode
        // work on the benchmark meeting was padding. `.none` runs WhisperKit's
        // native sequential seek loop instead, which fills its windows and
        // carries prompt context between them. Which one wins is a measurement,
        // so it is a key rather than a rewrite.
        let chunkingStrategy = chunking(defaults, Key.chunking, or: defaultChunking)

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
            // Read from the resolved value, not `decoding.chunkingStrategy`: an
            // optional there would print "none" for both `.none` and unset.
            "chunking=\(chunkingStrategy.rawValue)",
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

    // These read the raw object and parse it themselves rather than using
    // `integer(forKey:)` / `float(forKey:)` / `bool(forKey:)`, for two reasons.
    // Those accessors return `0`/`false` for an absent key, which would make a
    // deliberate `0` indistinguishable from "not set"; and command-line
    // overrides arrive in the argument domain as *strings*, where the accessors
    // coerce anything unparseable to `0` — `-whisperLogProbThreshold abc` would
    // silently run at 0.0 (failing nearly every window) and the decimal-comma
    // typo `2,4` would silently become 2.0. A bogus argument has to cost a
    // comparison, not corrupt one.

    /// `nil` when the key is absent or its value is not a number, so the caller
    /// falls back to the default.
    private static func int(_ defaults: UserDefaults, _ key: String) -> Int? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(trimmed(string))
        default: return nil
        }
    }

    private static func float(_ defaults: UserDefaults, _ key: String) -> Float? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber: return number.floatValue
        case let string as String: return Float(trimmed(string))
        default: return nil
        }
    }

    /// Accepts the spellings a `defaults write` or a command-line argument
    /// realistically produces; anything else is a typo, not a `false`.
    private static func bool(_ defaults: UserDefaults, _ key: String, or fallback: Bool) -> Bool {
        switch defaults.object(forKey: key) {
        case let number as NSNumber: return number.boolValue
        case let string as String:
            switch trimmed(string).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return fallback
            }
        default: return fallback
        }
    }

    private static func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespaces)
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

    /// Same shape as `computeUnits`: an unrecognised spelling is a typo in a
    /// benchmark argument, so it costs a comparison rather than the run.
    private static func chunking(
        _ defaults: UserDefaults,
        _ key: String,
        or fallback: ChunkingStrategy
    ) -> ChunkingStrategy {
        switch defaults.string(forKey: key).map({ trimmed($0).lowercased() }) {
        case "vad": return .vad
        case "none": return ChunkingStrategy.none
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
