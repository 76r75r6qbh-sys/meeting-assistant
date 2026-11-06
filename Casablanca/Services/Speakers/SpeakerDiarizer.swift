import Foundation
import FluidAudio

// MARK: - FluidAudio API findings (Task A5 Step 1, verified 2026-11-05)
//
// Package: https://github.com/FluidInference/FluidAudio.git pinned EXACTLY at
// 0.17.7 (tag v0.17.7 = 503b4bd1, 2026-10-07: the newest release at least two
// weeks old; 0.18.x is from 2026-10-28 and later). `swift-tools-version: 6.0`
// (plus a `Package@swift-6.2.swift` with traits), `.macOS(.v14)`, no package
// dependencies, but one prebuilt binary target (`NemoTextProcessing`, Apache-2.0,
// text normalisation for TTS; linked by default, unused here). The Swift-6
// package builds in this Swift-5 app target: packages compile in their own
// language mode.
//
// Offline API, read from the checkout (Diarizer/Offline/Core):
// - `OfflineDiarizerManager(config: OfflineDiarizerConfig())` — a non-Sendable
//   final class.
// - `prepareModels(directory: URL? = nil, configuration:, forceRedownload:)`
//   DOES take a directory, but reports no progress. Progress comes from
//   `OfflineDiarizerModels.load(from:configuration:progressHandler:)` (a
//   Sendable struct), handed to the manager with `initialize(models:)`. That is
//   what this adapter does, so the models load once and every diarization gets
//   a fresh manager (no shared non-Sendable state). `ModelHub.loadModels`
//   itself purges a damaged cache and re-downloads once (errors surface as
//   FluidAudio's `DownloadError`, not `URLError`), so there is no extra retry.
// - Cancellation: segmentation, embedding and PLDA loops call
//   `Task.checkCancellation()`, so cancelling the task running `process`
//   stops a run at the next chunk; the speaker step's timeout does that.
// - Models: Hugging Face `FluidInference/speaker-diarization-coreml`, pinned by
//   FluidAudio to revision df2625ac; only `Segmentation`, `FBank`, `Embedding`,
//   `PldaRho` (.mlmodelc) and `plda-parameters.json` are fetched for the
//   offline variant, into `<directory>/speaker-diarization-coreml`.
// - `process(_ url: URL)` decodes through `AVAudioFile` and resamples to
//   16 kHz mono, so it reads our WAV and m4a tracks directly (no own decoder).
// - Result: `DiarizationResult.segments[i].speakerId` ("S1"…),
//   `.startTimeSeconds` / `.endTimeSeconds` (Float), `.embedding` per segment,
//   plus `speakerDatabase: [String: [Float]]?` — the per-speaker MEAN segment
//   embedding (not normalised). So per-speaker embeddings ARE exposed (A7); we
//   L2-normalise them. NOTE: a segment's `.embedding` is its whole-meeting
//   cluster CENTROID (OfflineReconstruction `appendSegment`), not an embedding
//   of that segment's audio. There is no public span embedder
//   (`OfflineEmbeddingExtractor.embedSpan` is internal), so
//   `embedding(trackURL:ranges:)` reads ONLY the ranges into memory
//   (`VoiceSpanExtractor`), runs `process(audio:)` on that short buffer, and
//   takes the dominant cluster's vector — nothing outside the ranges counts.
// - macOS 14 has an Apple BNNS bug that can CRASH offline diarization
//   (FluidAudio #878, fixed in macOS 15). A crash would fail the pipeline, so
//   this adapter refuses to run before macOS 15 (→ "Others" fallback).
// - Sortformer is not used.
//
// Licences (allowed: Apache-2.0 / MIT / BSD / CC-BY-4.0):
// - FluidAudio: Apache-2.0. ThirdPartyLicenses: fastcluster (BSD-2-Clause),
//   VBx (Apache-2.0), NemoTextProcessing / text-processing-rs (Apache-2.0),
//   TTS-only G2P data (Apache-2.0 / MIT / BSD; not used here).
// - Models (Community-1 artifact set, NOTICE.md scope): CC-BY-4.0 — pyannote
//   speaker-diarization-community-1 (segmentation, WeSpeaker embedding),
//   PLDA from BUT Speech@FIT (CC-BY-4.0 incl. commercial use), converted to
//   Core ML by Fluid Inference (modified). Legacy artifacts in the same repo
//   (MIT / CC-BY-4.0) are not downloaded.

/// One speaker turn from the diarizer: `clusterKey` is the diarizer's own
/// label, renumbered to `S1…` by `SpeakerTranscriptBuilder.assignClusters`.
struct DiarizedTurn: Equatable, Sendable {
    var start: Double
    var end: Double
    var clusterKey: String
}

struct DiarizationOutput: Equatable, Sendable {
    var turns: [DiarizedTurn]
    /// clusterKey → L2-normalised centroid; empty if the API exposes none.
    var embeddings: [String: [Float]]
}

/// Offline speaker diarization of one track. Tests inject a fake; nothing in
/// a test may download or run the real models.
protocol SpeakerDiarizing: Sendable {
    /// Downloads (first time) and loads the models. `progress` gets a fraction
    /// in 0…1, or nil when the step has no measurable progress.
    func prepareModels(progress: @escaping @Sendable (Double?) -> Void) async throws
    func diarize(trackURL: URL) async throws -> DiarizationOutput
    /// The L2-normalised voice embedding of the speech in `ranges` (seconds),
    /// computed from those ranges only.
    func embedding(trackURL: URL, ranges: [ClosedRange<Double>]) async throws -> [Float]
    /// False when diarization can never run here (FluidAudio on macOS < 15).
    /// The speaker step then skips it silently; Settings explains why.
    var isAvailable: Bool { get }
}

extension SpeakerDiarizing {
    var isAvailable: Bool { true }
}

enum SpeakerDiarizerError: LocalizedError, Equatable {
    case unsupportedOS
    case noSpeechInRanges

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Speaker recognition needs macOS 15 or later."
        case .noSpeechInRanges:
            return "No speech found in the selected ranges."
        }
    }
}

/// `SpeakerDiarizing` on FluidAudio's offline (pyannote Community-1 + VBx)
/// pipeline. Models live under `Application Support/Casablanca/Models/FluidAudio`.
final class FluidAudioDiarizer: SpeakerDiarizing {
    /// One instance for the app, so Settings' "Download now" and the pipeline
    /// share the loaded models.
    static let shared = FluidAudioDiarizer()

    private let modelsDirectory: URL
    private let cache = ModelCache()

    init(modelsDirectory: URL = FluidAudioDiarizer.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    static var defaultModelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Casablanca/Models/FluidAudio", isDirectory: true)
    }

    var isAvailable: Bool { Self.isSupportedOS }

    /// The files FluidAudio needs for the offline diarizer, under `directory`.
    static func requiredModelURLs(in directory: URL) -> [URL] {
        let repo = directory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        return ModelNames.OfflineDiarizer.requiredModels.sorted().map { repo.appendingPathComponent($0) }
    }

    /// Whether every model file is already on disk (a download finished earlier).
    static func modelsCached(in directory: URL) -> Bool {
        requiredModelURLs(in: directory).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// FluidAudio's offline diarizer can crash on macOS 14 (BNNS bug #878).
    static var isSupportedOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    func prepareModels(progress: @escaping @Sendable (Double?) -> Void) async throws {
        _ = try await models(progress: progress)
    }

    func diarize(trackURL: URL) async throws -> DiarizationOutput {
        let result = try await process(trackURL: trackURL)
        let turns = result.segments
            .map { DiarizedTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), clusterKey: $0.speakerId) }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var embeddings: [String: [Float]] = [:]
        for (key, vector) in result.speakerDatabase ?? [:] {
            if let normalised = Self.l2Normalised(vector) { embeddings[key] = normalised }
        }
        return DiarizationOutput(turns: turns, embeddings: embeddings)
    }

    func embedding(trackURL: URL, ranges: [ClosedRange<Double>]) async throws -> [Float] {
        let audio = try VoiceSpanExtractor.samples(url: trackURL, ranges: ranges)
        guard !audio.isEmpty else { throw SpeakerDiarizerError.noSpeechInRanges }
        let manager = try await makeManager()
        let result = try await manager.process(audio: audio)
        let durations = result.segments.map {
            (speakerID: $0.speakerId, seconds: Double($0.endTimeSeconds - $0.startTimeSeconds))
        }
        guard let embedding = Self.dominantEmbedding(durations: durations, database: result.speakerDatabase ?? [:]) else {
            throw SpeakerDiarizerError.noSpeechInRanges
        }
        return embedding
    }

    /// The L2-normalised vector of the cluster with the most speech; ties go
    /// to the smaller id. Nil when no cluster with speech has a vector.
    static func dominantEmbedding(
        durations: [(speakerID: String, seconds: Double)],
        database: [String: [Float]]
    ) -> [Float]? {
        var total: [String: Double] = [:]
        for entry in durations where entry.seconds > 0 { total[entry.speakerID, default: 0] += entry.seconds }
        let ranked = total.keys.sorted { total[$0]! != total[$1]! ? total[$0]! > total[$1]! : $0 < $1 }
        for id in ranked {
            if let vector = database[id], let normalised = l2Normalised(vector) { return normalised }
        }
        return nil
    }

    // MARK: - Internals

    private func process(trackURL: URL) async throws -> DiarizationResult {
        try await makeManager().process(trackURL)
    }

    /// A fresh manager per run: it is not Sendable, the models are.
    private func makeManager() async throws -> OfflineDiarizerManager {
        let models = try await models(progress: { _ in })
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        manager.initialize(models: models)
        return manager
    }

    private func models(progress: @escaping @Sendable (Double?) -> Void) async throws -> OfflineDiarizerModels {
        guard Self.isSupportedOS else { throw SpeakerDiarizerError.unsupportedOS }
        return try await cache.models(directory: modelsDirectory, progress: progress)
    }

    static func l2Normalised(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    /// Loads the models once; concurrent callers share the one load.
    private actor ModelCache {
        private var loaded: OfflineDiarizerModels?
        private var loading: Task<OfflineDiarizerModels, Error>?

        func models(directory: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> OfflineDiarizerModels {
            if let loaded { return loaded }
            if let loading { return try await loading.value }
            let task = Task<OfflineDiarizerModels, Error> {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // FluidAudio's ModelHub already purges a damaged cache and
                // re-downloads once; no second retry layer here.
                return try await OfflineDiarizerModels.load(
                    from: directory,
                    progressHandler: { progress($0.fractionCompleted) }
                )
            }
            loading = task
            do {
                let models = try await task.value
                loaded = models
                loading = nil
                return models
            } catch {
                loading = nil
                throw error
            }
        }
    }
}
