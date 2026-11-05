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
    /// seconds of it, in the track the speaker was heard on: the mic track for
    /// `.microphone` and `.room` speakers, the system track for `.system`.
    /// `nil` when the speaker has no segments or the track file is gone (the
    /// user does not keep speaker tracks, or an old meeting).
    @MainActor
    static func clip(for speakerID: String, meeting: Meeting) -> SpeakerClip? {
        guard let speaker = meeting.speakers.first(where: { $0.id == speakerID }) else { return nil }
        var longest: SpeakerSegment?
        for segment in meeting.speakerSegments where segment.speakerID == speakerID {
            if segment.end - segment.start > (longest.map { $0.end - $0.start } ?? 0) {
                longest = segment
            }
        }
        guard let longest else { return nil }

        let path: String?
        switch speaker.source {
        case .microphone, .room: path = meeting.micTrackFileURL
        case .system: path = meeting.systemTrackFileURL
        }
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return SpeakerClip(
            url: URL(fileURLWithPath: path),
            start: longest.start,
            duration: min(maxClipDuration, longest.end - longest.start)
        )
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
}
