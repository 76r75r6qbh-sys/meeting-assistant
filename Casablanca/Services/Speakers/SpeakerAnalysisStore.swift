import Foundation

/// A name the app could offer for a speaker. Only ever a suggestion: owners
/// and names are never applied silently (Global Constraints).
struct SpeakerNameSuggestion: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case transcript, voiceProfile
    }

    var speakerID: String
    var name: String
    var evidence: String
    var source: Source
    var score: Double?
}

/// What the speaker step found for one meeting, beside the meeting itself.
/// Holds no biometric data: no embeddings, no audio.
struct SpeakerAnalysisRecord: Codable, Equatable, Sendable {
    var meetingID: UUID
    var diarization: DiarizationOutcome
    var suggestions: [SpeakerNameSuggestion]
}

/// One JSON sidecar per meeting, `<meetingID>.json`, under
/// `Application Support/Casablanca/Speakers`.
struct SpeakerAnalysisStore: Sendable {
    let directory: URL

    init(directory: URL = SpeakerAnalysisStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Casablanca/Speakers", isDirectory: true)
    }

    func load(_ meetingID: UUID) -> SpeakerAnalysisRecord? {
        guard let data = try? Data(contentsOf: fileURL(meetingID)) else { return nil }
        return try? JSONDecoder().decode(SpeakerAnalysisRecord.self, from: data)
    }

    func save(_ record: SpeakerAnalysisRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: fileURL(record.meetingID), options: .atomic)
    }

    /// Best-effort: a missing sidecar is fine.
    func delete(_ meetingID: UUID) {
        let url = fileURL(meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        bestEffort("delete speaker analysis sidecar", Log.transcription) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func fileURL(_ meetingID: UUID) -> URL {
        directory.appendingPathComponent("\(meetingID.uuidString).json")
    }
}
