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
    /// The capture source of segments that a cross-source merge moved to a
    /// speaker heard on another track, keyed by
    /// `SpeakerClipSelector.segmentKey`, so their samples still play from the
    /// track they were recorded on. Absent in older sidecars.
    var segmentSources: [String: SpeakerSource]? = nil
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

    /// Posted after every successful `save`, with the meeting's id under
    /// ``meetingIDKey``, so a speakers bar shows suggestions that arrive after
    /// it appeared. Posted on the main thread.
    static let recordDidChange = Notification.Name("SpeakerAnalysisStore.recordDidChange")
    static let meetingIDKey = "meetingID"

    func save(_ record: SpeakerAnalysisRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: fileURL(record.meetingID), options: .atomic)
        let meetingID = record.meetingID
        let post: @Sendable () -> Void = {
            NotificationCenter.default.post(
                name: Self.recordDidChange,
                object: nil,
                userInfo: [Self.meetingIDKey: meetingID]
            )
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
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
