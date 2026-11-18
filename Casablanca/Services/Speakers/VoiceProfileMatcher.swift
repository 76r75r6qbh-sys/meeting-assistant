import Foundation

/// Matches a meeting's cluster embeddings against the saved voice profiles.
/// A match is only ever a name suggestion; it never renames a speaker.
enum VoiceProfileMatcher {
    /// Cosine similarity on L2-normalised 256-d WeSpeaker embeddings. A
    /// conservative start: a miss costs a suggestion, a match only suggests.
    static let defaultThreshold: Float = 0.80

    static let evidence = "Voice profile match"

    /// 0 for vectors of different dimensions or a zero vector.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        let denominator = normA.squareRoot() * normB.squareRoot()
        guard denominator > 0, denominator.isFinite else { return 0 }
        return dot / denominator
    }

    /// The best profile per cluster at or above `threshold`, keyed by speaker
    /// id (`S1…`). Each profile names at most one cluster: pairs are taken
    /// highest score first. Sorted by speaker id.
    static func suggestions(
        clusterEmbeddings: [String: [Float]],
        profiles: [VoiceProfile],
        threshold: Float = defaultThreshold
    ) -> [SpeakerNameSuggestion] {
        var pairs: [(speakerID: String, profile: VoiceProfile, score: Float)] = []
        for (speakerID, embedding) in clusterEmbeddings {
            for profile in profiles {
                let score = cosine(embedding, profile.centroid)
                if score >= threshold { pairs.append((speakerID, profile, score)) }
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.speakerID != rhs.speakerID { return lhs.speakerID < rhs.speakerID }
            return lhs.profile.name < rhs.profile.name
        }

        var usedSpeakers = Set<String>()
        var usedProfiles = Set<UUID>()
        var suggestions: [SpeakerNameSuggestion] = []
        for pair in pairs where !usedSpeakers.contains(pair.speakerID) && !usedProfiles.contains(pair.profile.id) {
            usedSpeakers.insert(pair.speakerID)
            usedProfiles.insert(pair.profile.id)
            suggestions.append(SpeakerNameSuggestion(
                speakerID: pair.speakerID,
                name: pair.profile.name,
                evidence: evidence,
                source: .voiceProfile,
                score: Double(pair.score)
            ))
        }
        return suggestions.sorted { $0.speakerID.localizedStandardCompare($1.speakerID) == .orderedAscending }
    }
}
