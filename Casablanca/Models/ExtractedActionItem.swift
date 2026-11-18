import Foundation

/// Whether an extracted action item's quote was checked against the transcript.
enum VerificationState: String, Codable {
    case unverified, supported, unsupported
}

/// One action item as extracted from a transcript, before it becomes a to-do.
struct ExtractedActionItem: Codable, Equatable {
    var task: String
    var owner: String?
    /// ISO date (`yyyy-MM-dd`).
    var due: String?
    /// `true` when the due date was stated in the meeting, not inferred.
    var dueIsExplicit: Bool
    var confidence: Double
    /// Supporting quote from the transcript.
    var quote: String?
    /// Transcript timestamp label of the quote (`mm:ss` or `h:mm:ss`).
    var timestamp: String?
    var verified: VerificationState
    var verificationReason: String?
}

/// JSON coding for a meeting's extracted action items. Decoding `nil` or
/// unreadable data yields `[]`.
enum ActionItemData {
    static func encode(_ items: [ExtractedActionItem]) -> Data? {
        try? JSONEncoder().encode(items)
    }

    static func decode(_ data: Data?) -> [ExtractedActionItem] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([ExtractedActionItem].self, from: data)) ?? []
    }
}
