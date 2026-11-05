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
