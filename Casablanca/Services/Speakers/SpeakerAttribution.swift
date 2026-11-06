import Foundation

/// The speaker ids Track A owns (cross-track ruling R3).
enum SpeakerIDs {
    /// The user, heard on the microphone.
    static let me = "me"
    /// The undiarized system track: everyone on the far end of the call.
    static let others = "others"
    /// A diarized cluster, numbered by first appearance in time: `S1`, `S2`, ….
    static func cluster(_ ordinal: Int) -> String { "S\(ordinal)" }
}

/// Which capture path a span of speech came from.
enum AttributedSource: Equatable, Sendable {
    case microphone, system, undetermined
}

/// Attributes transcript words to the microphone or the system track by
/// comparing their energy, with a guard against the remote voice leaking from
/// the speakers into the mic ("bleed").
///
/// Deterministic: the same envelopes, segments and thresholds always give the
/// same output. Every threshold is pinned by
/// `SpeakerAttributionTests.testDefaultThresholdsArePinned`.
struct SpeakerAttribution: Sendable {
    struct Thresholds: Equatable, Sendable {
        /// The mix gains: what each track contributes to what Whisper heard.
        var micGain: Float = 1.35
        var systemGain: Float = 0.8
        /// Both tracks' span RMS (before gain) below this: nobody spoke.
        var silenceFloorRMS: Float = 0.004
        var micShareForMic: Float = 0.65
        var micShareForSystem: Float = 0.35
        /// A mic envelope this correlated with the system envelope is the
        /// speakers playing into the mic.
        var bleedCorrelation: Float = 0.80
        /// Mic lags tried, in frames (0–200 ms): the mic hears the speakers late.
        var bleedMaxLagFrames = 4
        /// Spans shorter than this (seconds) are padded symmetrically before
        /// correlating, so a short word still has a meaningful window.
        var bleedMinWindow = 0.6
        /// Source runs shorter than this (seconds) are absorbed by a neighbour.
        var minRunDuration = 0.6

        static let `default` = Thresholds()
    }

    let mic: EnergyEnvelope?
    let system: EnergyEnvelope?
    let thresholds: Thresholds

    init(mic: EnergyEnvelope?, system: EnergyEnvelope?, thresholds: Thresholds = .default) {
        self.mic = mic
        self.system = system
        self.thresholds = thresholds
    }

    // MARK: - Spans

    /// The source of `[from, to]` seconds.
    func source(from: Double, to: Double) -> AttributedSource {
        let micRMS = (mic?.meanSquare(from: from, to: to) ?? 0).squareRoot()
        let systemRMS = (system?.meanSquare(from: from, to: to) ?? 0).squareRoot()

        if micRMS < thresholds.silenceFloorRMS, systemRMS < thresholds.silenceFloorRMS {
            return .undetermined
        }
        if systemRMS > thresholds.silenceFloorRMS,
           let correlation = bleedCorrelation(from: from, to: to),
           correlation >= thresholds.bleedCorrelation {
            return .system
        }
        guard let share = micShare(from: from, to: to) else { return .undetermined }
        if share >= thresholds.micShareForMic { return .microphone }
        if share <= thresholds.micShareForSystem { return .system }
        return .undetermined
    }

    /// `Σm² / (Σm² + Σs²)` over the span, with `m`/`s` the gain-weighted frame
    /// RMS. `nil` when both are zero.
    func micShare(from: Double, to: Double) -> Float? {
        let range = EnergyEnvelope.frameRange(from: from, to: to)
        var micEnergy: Double = 0
        var systemEnergy: Double = 0
        for index in range {
            let m = Double((mic?.value(at: index) ?? 0) * thresholds.micGain)
            let s = Double((system?.value(at: index) ?? 0) * thresholds.systemGain)
            micEnergy += m * m
            systemEnergy += s * s
        }
        let total = micEnergy + systemEnergy
        guard total > 0 else { return nil }
        return Float(micEnergy / total)
    }

    /// The highest Pearson correlation between the system envelope and the mic
    /// envelope delayed by 0…`bleedMaxLagFrames` frames, over the span padded to
    /// `bleedMinWindow`. `nil` without both envelopes; a flat window counts as 0.
    func bleedCorrelation(from: Double, to: Double) -> Float? {
        guard let mic, let system else { return nil }
        var lower = from
        var upper = to
        if upper - lower < thresholds.bleedMinWindow {
            let center = (lower + upper) / 2
            lower = center - thresholds.bleedMinWindow / 2
            upper = center + thresholds.bleedMinWindow / 2
        }
        let range = EnergyEnvelope.frameRange(from: max(0, lower), to: upper)
        var best: Double = 0
        for lag in 0...max(0, thresholds.bleedMaxLagFrames) {
            let systemValues = range.map { Double(system.value(at: $0)) }
            let micValues = range.map { Double(mic.value(at: $0 + lag)) }
            best = max(best, Self.pearson(systemValues, micValues))
        }
        return Float(best)
    }

    // MARK: - Segments

    /// Attributes each segment: per word when it has words, otherwise as a
    /// whole. A segment whose source changes for at least `minRunDuration` is
    /// split there. Without any envelope (an old meeting) the segments come back
    /// unattributed (`speakerID == nil`), words carried over.
    func attribute(_ segments: [TranscriptSegment]) -> [SpeakerSegment] {
        guard mic != nil || system != nil else {
            return segments.map {
                SpeakerSegment(start: $0.startTime, end: $0.endTime, speakerID: nil, text: $0.text, words: $0.words)
            }
        }
        return segments.flatMap(attribute)
    }

    /// The per-word sources with `.undetermined` filled in: a word inherits the
    /// previous word's source, leading words the first determined one, and an
    /// all-undetermined list gets ``fallbackSource``.
    func resolvedSources(for words: [TranscriptWord]) -> [AttributedSource] {
        resolve(words.map { source(from: $0.start, to: $0.end) })
    }

    /// The source of speech no energy can place: the user when there is no
    /// system track (a mic-only recording), otherwise the far end.
    var fallbackSource: AttributedSource {
        system == nil ? .microphone : .system
    }

    private func attribute(_ segment: TranscriptSegment) -> [SpeakerSegment] {
        guard let words = segment.words, !words.isEmpty else {
            let resolved = resolve([source(from: segment.startTime, to: segment.endTime)])[0]
            return [whole(segment, source: resolved)]
        }

        let runs = absorbShortRuns(makeRuns(words: words, sources: resolvedSources(for: words)))
        guard runs.count > 1 else { return [whole(segment, source: runs[0].source)] }

        return runs.map { run in
            let runWords = Array(words[run.range])
            return SpeakerSegment(
                start: runWords[0].start,
                end: runWords[runWords.count - 1].end,
                speakerID: Self.speakerID(for: run.source),
                // Same clean-up as Whisper's segment text (control tokens,
                // whitespace, space before punctuation); the words stay raw.
                text: WhisperTextCleaner.clean(runWords.map(\.text).joined()),
                words: runWords
            )
        }
    }

    private func whole(_ segment: TranscriptSegment, source: AttributedSource) -> SpeakerSegment {
        SpeakerSegment(
            start: segment.startTime,
            end: segment.endTime,
            speakerID: Self.speakerID(for: source),
            text: segment.text,
            words: segment.words
        )
    }

    private func resolve(_ sources: [AttributedSource]) -> [AttributedSource] {
        guard let firstDetermined = sources.first(where: { $0 != .undetermined }) else {
            return sources.map { _ in fallbackSource }
        }
        var previous = firstDetermined
        return sources.map { source in
            if source != .undetermined { previous = source }
            return previous
        }
    }

    // MARK: - Runs

    private struct Run {
        var source: AttributedSource
        var range: Range<Int>
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    private func makeRuns(words: [TranscriptWord], sources: [AttributedSource]) -> [Run] {
        var runs: [Run] = []
        for (index, word) in words.enumerated() {
            if var last = runs.last, last.source == sources[index] {
                last.range = last.range.lowerBound..<(index + 1)
                last.end = word.end
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(source: sources[index], range: index..<(index + 1), start: word.start, end: word.end))
            }
        }
        return runs
    }

    /// Repeatedly merges the first run shorter than `minRunDuration` into the
    /// preceding run (into the following one at segment start), then coalesces
    /// neighbours of the same source, until every run is long enough or one
    /// run is left.
    private func absorbShortRuns(_ input: [Run]) -> [Run] {
        var runs = input
        while runs.count > 1,
              let index = runs.firstIndex(where: { $0.duration < thresholds.minRunDuration }) {
            let target = index == 0 ? 1 : index - 1
            let merged = Run(
                source: runs[target].source,
                range: min(runs[index].range.lowerBound, runs[target].range.lowerBound)
                    ..< max(runs[index].range.upperBound, runs[target].range.upperBound),
                start: min(runs[index].start, runs[target].start),
                end: max(runs[index].end, runs[target].end)
            )
            runs[min(index, target)] = merged
            runs.remove(at: max(index, target))
            runs = coalesce(runs)
        }
        return runs
    }

    private func coalesce(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs {
            if var last = out.last, last.source == run.source {
                last.range = last.range.lowerBound..<run.range.upperBound
                last.end = max(last.end, run.end)
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func speakerID(for source: AttributedSource) -> String? {
        switch source {
        case .microphone: return SpeakerIDs.me
        case .system: return SpeakerIDs.others
        case .undetermined: return nil
        }
    }

    /// Pearson correlation; 0 for fewer than 3 points or a flat series.
    private static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let count = min(x.count, y.count)
        guard count >= 3 else { return 0 }
        let meanX = x.prefix(count).reduce(0, +) / Double(count)
        let meanY = y.prefix(count).reduce(0, +) / Double(count)
        var covariance: Double = 0
        var varianceX: Double = 0
        var varianceY: Double = 0
        for index in 0..<count {
            let dx = x[index] - meanX
            let dy = y[index] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        let denominator = (varianceX * varianceY).squareRoot()
        guard denominator > 1e-12 else { return 0 }
        return covariance / denominator
    }
}
