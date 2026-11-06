import Foundation

/// A short sample of one speaker in a speaker track.
struct SpeakerClip: Equatable {
    var url: URL
    var start: Double
    var duration: Double
}

/// Picks what the speakers bar plays and shows for each speaker.
enum SpeakerClipSelector {
    /// Longest sample played, in seconds.
    static let maxClipDuration = 5.0

    /// The speaker's longest segment (the earliest on ties), at most five
    /// seconds of it, in the track that segment was heard on: the mic track for
    /// `.microphone` and `.room`, the system track for `.system`. A segment's
    /// source is the speaker's, unless `sourceOverrides` (the sidecar's
    /// `segmentSources`, written by a cross-source merge) says otherwise.
    /// `nil` when the speaker has no segments or that track file is gone (the
    /// user does not keep speaker tracks, or an old meeting).
    @MainActor
    static func clip(
        for speakerID: String,
        meeting: Meeting,
        sourceOverrides: [String: SpeakerSource] = [:]
    ) -> SpeakerClip? {
        guard let speaker = meeting.speakers.first(where: { $0.id == speakerID }) else { return nil }
        var longest: SpeakerSegment?
        for segment in meeting.speakerSegments where segment.speakerID == speakerID {
            if segment.end - segment.start > (longest.map { $0.end - $0.start } ?? 0) {
                longest = segment
            }
        }
        guard let longest else { return nil }

        let source = sourceOverrides[segmentKey(longest)] ?? speaker.source
        guard let path = trackPath(for: source, meeting: meeting), FileManager.default.fileExists(atPath: path) else { return nil }
        return SpeakerClip(
            url: URL(fileURLWithPath: path),
            start: longest.start,
            duration: min(maxClipDuration, longest.end - longest.start)
        )
    }

    /// Most speech "Remember voice…" embeds, in seconds.
    static let maxVoiceSampleDuration = 30.0

    /// What "Remember voice…" embeds: the speaker's longest segments on the
    /// speaker's own track (segments a cross-source merge brought in from the
    /// other track are left out), up to `maxDuration` seconds in all, the last
    /// one cut short; ranges in time order. `nil` when that track file is
    /// gone or the speaker has no segments on it.
    @MainActor
    static func voiceSample(
        for speakerID: String,
        meeting: Meeting,
        sourceOverrides: [String: SpeakerSource] = [:],
        maxDuration: Double = maxVoiceSampleDuration
    ) -> (url: URL, ranges: [ClosedRange<Double>])? {
        guard let speaker = meeting.speakers.first(where: { $0.id == speakerID }),
              let path = trackPath(for: speaker.source, meeting: meeting),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        let onTrack = meeting.speakerSegments.filter { segment in
            segment.speakerID == speakerID
                && segment.end > segment.start
                && trackPath(for: sourceOverrides[segmentKey(segment)] ?? speaker.source, meeting: meeting) == path
        }
        // Longest first; the earlier one on ties.
        let longestFirst = onTrack.sorted { lhs, rhs in
            let left = lhs.end - lhs.start, right = rhs.end - rhs.start
            return left != right ? left > right : lhs.start < rhs.start
        }
        var ranges: [ClosedRange<Double>] = []
        var left = maxDuration
        for segment in longestFirst where left > 0 {
            let length = min(segment.end - segment.start, left)
            ranges.append(segment.start...(segment.start + length))
            left -= length
        }
        guard !ranges.isEmpty else { return nil }
        return (URL(fileURLWithPath: path), ranges.sorted { $0.lowerBound < $1.lowerBound })
    }

    /// The track a source was recorded on: the mic track for `.microphone`
    /// and `.room`, the system track for `.system`.
    @MainActor
    private static func trackPath(for source: SpeakerSource, meeting: Meeting) -> String? {
        switch source {
        case .microphone, .room: return meeting.micTrackFileURL
        case .system: return meeting.systemTrackFileURL
        }
    }

    /// A segment's identity in the sidecar: its time range to the millisecond.
    static func segmentKey(_ segment: SpeakerSegment) -> String {
        String(format: "%.3f-%.3f", segment.start, segment.end)
    }

    /// Each speaker's share of the attributed talk time, 0…1, summing to 1.
    /// Unattributed segments do not count. `[:]` when nobody spoke.
    static func talkTimeShares(_ segments: [SpeakerSegment]) -> [String: Double] {
        var seconds: [String: Double] = [:]
        for segment in segments {
            guard let id = segment.speakerID else { continue }
            seconds[id, default: 0] += max(0, segment.end - segment.start)
        }
        let total = seconds.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return seconds.mapValues { $0 / total }
    }

    /// ``talkTimeShares`` as whole percentages that add up to exactly 100
    /// (largest remainder: every share is floored, then the points left go to
    /// the largest remainders, ties to the smaller id). `[:]` when nobody spoke.
    static func talkTimePercentages(_ segments: [SpeakerSegment]) -> [String: Int] {
        let shares = talkTimeShares(segments)
        guard !shares.isEmpty else { return [:] }
        var percentages = shares.mapValues { Int(($0 * 100).rounded(.down)) }
        let left = 100 - percentages.values.reduce(0, +)
        let byRemainder = shares.keys.sorted { lhs, rhs in
            let left = shares[lhs]! * 100 - Double(percentages[lhs]!)
            let right = shares[rhs]! * 100 - Double(percentages[rhs]!)
            if abs(left - right) > 1e-9 { return left > right }
            return lhs < rhs
        }
        for id in byRemainder.prefix(max(0, left)) {
            percentages[id, default: 0] += 1
        }
        return percentages
    }
}
