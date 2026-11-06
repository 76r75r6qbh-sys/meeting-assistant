import Foundation

/// Builds the `SpeakerInfo` list for attributed segments: one entry per
/// speaker id that occurs, in order of first appearance.
///
/// Labels (Global Constraints): the user is the first user-name alias, else
/// `Me` / `Ik`; the undiarized system track is `Others` / `Anderen`; clusters
/// are `Speaker N` / `Spreker N`. Dutch when `language` starts with `nl`.
/// Names pass through `TranscriptLineFormat.sanitizedSpeakerName` (R13) so
/// they render and parse back as line prefixes.
enum SpeakerTranscriptBuilder {

    static func speakers(
        for segments: [SpeakerSegment],
        language: String,
        userAliases: [String],
        hasSystemTrack: Bool,
        roomClusters: Bool
    ) -> [SpeakerInfo] {
        let dutch = isDutch(language)
        var seen = Set<String>()
        var speakers: [SpeakerInfo] = []
        for id in segments.compactMap(\.speakerID) where seen.insert(id).inserted {
            speakers.append(info(
                for: id,
                dutch: dutch,
                userAliases: userAliases,
                hasSystemTrack: hasSystemTrack,
                roomClusters: roomClusters
            ))
        }
        return speakers
    }

    // MARK: - Diarization

    /// Gives the words of `targetSpeakerID` segments (`"others"`, or `"me"` for
    /// an in-room meeting) the diarizer's clusters.
    ///
    /// A word gets the turn it overlaps most; with no overlap the nearest turn
    /// within 0.5 s; otherwise it keeps `targetSpeakerID`. A segment without
    /// words is placed as one word. Cluster runs shorter than `minRunDuration`
    /// are absorbed by a neighbour, then the segment is split where the speaker
    /// changes (as in A2's attribution). Cluster keys are renumbered `S1…` by
    /// first appearance in time; `clusterOrder[i]` is the key behind `S(i+1)`.
    /// Other segments come back unchanged.
    static func assignClusters(
        _ segments: [SpeakerSegment],
        turns: [DiarizedTurn],
        targetSpeakerID: String,
        minRunDuration: Double = 0.6,
        nearestTurnTolerance: Double = SpeakerTranscriptBuilder.nearestTurnTolerance
    ) -> (segments: [SpeakerSegment], clusterOrder: [String]) {
        let sortedTurns = turns.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        // Pass 1: labels are raw cluster keys (or the target id).
        var labelled: [(segment: SpeakerSegment, keys: [String]?)] = []
        for segment in segments {
            guard segment.speakerID == targetSpeakerID, !sortedTurns.isEmpty else {
                labelled.append((segment, nil))
                continue
            }
            let spans = segment.words.flatMap { $0.isEmpty ? nil : $0.map { ($0.start, $0.end) } }
                ?? [(segment.start, segment.end)]
            let keys = spans.map { span in
                clusterKey(from: span.0, to: span.1, turns: sortedTurns, tolerance: nearestTurnTolerance)
                    ?? targetSpeakerID
            }
            labelled.append((segment, keys))
        }

        // Pass 2: absorb short runs, split, and renumber by first appearance.
        var order: [String] = []
        var ids: [String: String] = [:]
        func id(for key: String) -> String {
            guard key != targetSpeakerID else { return targetSpeakerID }
            if let existing = ids[key] { return existing }
            order.append(key)
            let assigned = SpeakerIDs.cluster(order.count)
            ids[key] = assigned
            return assigned
        }

        var output: [SpeakerSegment] = []
        for (segment, keys) in labelled {
            guard let keys else {
                output.append(segment)
                continue
            }
            guard let words = segment.words, !words.isEmpty else {
                var whole = segment
                whole.speakerID = id(for: keys[0])
                output.append(whole)
                continue
            }
            let runs = absorbShortRuns(
                makeRuns(labels: keys, spans: words.map { ($0.start, $0.end) }),
                minRunDuration: minRunDuration
            )
            guard runs.count > 1 else {
                var whole = segment
                whole.speakerID = id(for: runs[0].label)
                output.append(whole)
                continue
            }
            for run in runs {
                let runWords = Array(words[run.range])
                output.append(SpeakerSegment(
                    start: runWords[0].start,
                    end: runWords[runWords.count - 1].end,
                    speakerID: id(for: run.label),
                    text: WhisperTextCleaner.clean(runWords.map(\.text).joined()),
                    words: runWords
                ))
            }
        }
        return (output, order)
    }

    /// A2's analysis with the diarizer's turns applied.
    ///
    /// With a system track the `"others"` words get clusters (words no turn
    /// claims stay `Others`). Without one (in-room, mic only) the `"me"` words
    /// are diarized: with at least two room clusters every speaker is a
    /// `.room` speaker (`isUser` false, `Speaker N`) — the user names their own
    /// cluster in A6 — so mic words no turn claims join the nearest cluster
    /// instead of being labelled the user. With at most one cluster the single
    /// user speaker stays (Review Focus 1). `diarization` reports the cluster
    /// count either way.
    static func diarizedResult(
        _ base: SpeakerAnalysisResult,
        turns: [DiarizedTurn],
        hasSystemTrack: Bool,
        language: String,
        userAliases: [String]
    ) -> SpeakerAnalysisResult {
        diarized(base, turns: turns, hasSystemTrack: hasSystemTrack, language: language, userAliases: userAliases).result
    }

    /// ``diarizedResult(_:turns:hasSystemTrack:language:userAliases:)`` plus
    /// the cluster key behind each `S(i+1)` in the result (`clusterOrder[i]`),
    /// so the speaker step can look up each speaker's embedding (A7). Empty
    /// when no cluster id was applied (in-room with fewer than two clusters).
    static func diarized(
        _ base: SpeakerAnalysisResult,
        turns: [DiarizedTurn],
        hasSystemTrack: Bool,
        language: String,
        userAliases: [String]
    ) -> (result: SpeakerAnalysisResult, clusterOrder: [String]) {
        let target = hasSystemTrack ? SpeakerIDs.others : SpeakerIDs.me
        // In-room, every mic word belongs to some room speaker: no distance
        // limit to the nearest turn.
        let assigned = assignClusters(
            base.segments,
            turns: turns,
            targetSpeakerID: target,
            nearestTurnTolerance: hasSystemTrack ? nearestTurnTolerance : .infinity
        )
        let clusterCount = assigned.clusterOrder.count
        if !hasSystemTrack, clusterCount < 2 {
            var unchanged = base
            unchanged.diarization = .succeeded(clusterCount: clusterCount)
            return (unchanged, [])
        }
        let result = SpeakerAnalysisResult(
            segments: assigned.segments,
            speakers: speakers(
                for: assigned.segments,
                language: language,
                userAliases: userAliases,
                hasSystemTrack: hasSystemTrack,
                roomClusters: !hasSystemTrack
            ),
            diarization: .succeeded(clusterCount: clusterCount)
        )
        return (result, assigned.clusterOrder)
    }

    /// The key of the turn overlapping `[from, to]` most; else the nearest turn
    /// within 0.5 s; else nil. Ties go to the earlier turn.
    private static func clusterKey(from: Double, to: Double, turns: [DiarizedTurn], tolerance: Double) -> String? {
        var best: (key: String, overlap: Double)?
        for turn in turns {
            let overlap = min(to, turn.end) - max(from, turn.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.clusterKey, overlap) }
        }
        if let best { return best.key }
        var nearest: (key: String, gap: Double)?
        for turn in turns {
            let gap = max(turn.start - to, from - turn.end, 0)
            if gap <= tolerance, gap < (nearest?.gap ?? .infinity) { nearest = (turn.clusterKey, gap) }
        }
        return nearest?.key
    }

    /// How far (seconds) a word may sit from the nearest turn and still get it.
    static let nearestTurnTolerance = 0.5

    private struct Run {
        var label: String
        var range: Range<Int>
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    private static func makeRuns(labels: [String], spans: [(Double, Double)]) -> [Run] {
        var runs: [Run] = []
        for (index, label) in labels.enumerated() {
            if var last = runs.last, last.label == label {
                last.range = last.range.lowerBound..<(index + 1)
                last.end = spans[index].1
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(label: label, range: index..<(index + 1), start: spans[index].0, end: spans[index].1))
            }
        }
        return runs
    }

    /// Same rule as `SpeakerAttribution`: repeatedly merge the first run shorter
    /// than `minRunDuration` into the preceding run (the following one at the
    /// segment start), coalescing equal neighbours, until one run is left or
    /// every run is long enough.
    private static func absorbShortRuns(_ input: [Run], minRunDuration: Double) -> [Run] {
        var runs = input
        while runs.count > 1, let index = runs.firstIndex(where: { $0.duration < minRunDuration }) {
            let target = index == 0 ? 1 : index - 1
            runs[min(index, target)] = Run(
                label: runs[target].label,
                range: min(runs[index].range.lowerBound, runs[target].range.lowerBound)
                    ..< max(runs[index].range.upperBound, runs[target].range.upperBound),
                start: min(runs[index].start, runs[target].start),
                end: max(runs[index].end, runs[target].end)
            )
            runs.remove(at: max(index, target))
            var coalesced: [Run] = []
            for run in runs {
                if var last = coalesced.last, last.label == run.label {
                    last.range = last.range.lowerBound..<run.range.upperBound
                    last.end = max(last.end, run.end)
                    coalesced[coalesced.count - 1] = last
                } else {
                    coalesced.append(run)
                }
            }
            runs = coalesced
        }
        return runs
    }

    static func isDutch(_ language: String) -> Bool {
        language.lowercased().hasPrefix("nl")
    }

    private static func info(
        for id: String,
        dutch: Bool,
        userAliases: [String],
        hasSystemTrack: Bool,
        roomClusters: Bool
    ) -> SpeakerInfo {
        switch id {
        case SpeakerIDs.me:
            let alias = userAliases.lazy
                .map(TranscriptLineFormat.sanitizedSpeakerName)
                .first(where: { !$0.isEmpty })
            return SpeakerInfo(
                id: id,
                displayName: alias ?? (dutch ? "Ik" : "Me"),
                source: .microphone,
                isUser: true,
                // A configured alias is the user's own name; the fallback is a label.
                nameConfirmed: alias != nil
            )
        case SpeakerIDs.others:
            return SpeakerInfo(
                id: id,
                displayName: dutch ? "Anderen" : "Others",
                source: .system,
                isUser: false,
                nameConfirmed: false
            )
        default:
            let ordinal = clusterOrdinal(id)
            let label = dutch ? "Spreker" : "Speaker"
            return SpeakerInfo(
                id: id,
                displayName: ordinal.map { "\(label) \($0)" } ?? TranscriptLineFormat.sanitizedSpeakerName(id),
                source: roomClusters || !hasSystemTrack ? .room : .system,
                isUser: false,
                nameConfirmed: false
            )
        }
    }

    /// `3` for `"S3"`; `nil` for anything that is not a cluster id.
    private static func clusterOrdinal(_ id: String) -> Int? {
        guard id.hasPrefix("S"), let ordinal = Int(id.dropFirst()), ordinal > 0 else { return nil }
        return ordinal
    }
}
