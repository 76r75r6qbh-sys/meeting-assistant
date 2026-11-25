import Foundation

// Speaker-attributed transcript value types (speech-pipeline Phase 0 contract).
//
// Stored on `Meeting` as JSON `Data?`. `Meeting.transcript` remains the
// canonical text; these hold the structure behind it. Named `SpeakerSegment`
// to stay clear of the live `TranscriptSegment` in TranscriptionService.

/// One recognised word with its time range in seconds from recording start.
struct TranscriptWord: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// One transcript line's worth of speech, attributed to a speaker when known.
struct SpeakerSegment: Codable, Equatable {
    var start: Double
    var end: Double
    /// `SpeakerInfo.id`; `nil` when the segment is not attributed.
    var speakerID: String?
    var text: String
    var words: [TranscriptWord]?
}

/// Which capture path a speaker was heard on.
enum SpeakerSource: String, Codable {
    case microphone, system, room
}

/// A speaker in one meeting: a stable id plus the name shown in the transcript.
struct SpeakerInfo: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var source: SpeakerSource
    var isUser: Bool
    var nameConfirmed: Bool
}

/// JSON coding for the speaker data stored on a meeting. Decoding `nil` or
/// unreadable data yields `[]`, so a damaged blob degrades to "no speakers".
enum SpeakerData {
    static func encodeSegments(_ segments: [SpeakerSegment]) -> Data? {
        try? JSONEncoder().encode(segments)
    }

    static func decodeSegments(_ data: Data?) -> [SpeakerSegment] {
        decode(data)
    }

    static func encodeSpeakers(_ speakers: [SpeakerInfo]) -> Data? {
        try? JSONEncoder().encode(speakers)
    }

    static func decodeSpeakers(_ data: Data?) -> [SpeakerInfo] {
        decode(data)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> [T] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
}
