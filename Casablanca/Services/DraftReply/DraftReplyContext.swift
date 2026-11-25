import Foundation

/// What a draft reply is about: a to-do and, when it has one, the meeting it
/// came from. A value snapshot, so the draft run never touches SwiftData.
struct DraftReplyContext: Equatable {
    let todoText: String
    let owner: String?
    let dueDate: Date?
    /// Raw `scheme:ref`, e.g. `jira:ABC-1234`; see ``TodoSourceLink``.
    let sourceRef: String?
    let meetingTitle: String?
    let meetingDate: Date?
    let meetingSummary: String?
    let transcriptExcerpt: String?

    /// A transcript up to this many characters goes into the prompt whole; the
    /// CLI's models take ~100k tokens of prompt comfortably.
    static let wholeTranscriptLimit = 300_000
    /// Size of the window cut from a longer transcript.
    static let transcriptWindowLength = 60_000

    init(
        todoText: String,
        owner: String?,
        dueDate: Date?,
        sourceRef: String?,
        meetingTitle: String?,
        meetingDate: Date?,
        meetingSummary: String?,
        transcriptExcerpt: String?
    ) {
        self.todoText = todoText
        self.owner = owner
        self.dueDate = dueDate
        self.sourceRef = sourceRef
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.meetingSummary = meetingSummary
        self.transcriptExcerpt = transcriptExcerpt
    }

    init(todo: TodoItem) {
        let meeting = todo.meeting
        self.init(
            todoText: todo.text,
            owner: todo.owner,
            dueDate: todo.dueDate,
            sourceRef: todo.sourceRef,
            meetingTitle: meeting?.title,
            meetingDate: meeting?.date,
            meetingSummary: meeting?.summary,
            transcriptExcerpt: Self.transcriptExcerpt(meeting?.transcript, around: todo.sourceTimestamp)
        )
    }

    /// The whole transcript if it is at most ``wholeTranscriptLimit`` characters.
    /// Otherwise a ``transcriptWindowLength`` window centered on the first
    /// `[timestamp]` label, or the start of the transcript when there is no label
    /// or it does not occur. The label is matched with its brackets so `5:00`
    /// cannot match inside `[45:00]`.
    static func transcriptExcerpt(_ transcript: String?, around timestamp: String?) -> String? {
        guard let transcript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let total = transcript.count
        guard total > wholeTranscriptLimit else { return transcript }

        var start = 0
        if let label = timestamp?.trimmingCharacters(in: .whitespaces), !label.isEmpty,
           let match = transcript.range(of: "[\(label)]") {
            let center = transcript.distance(from: transcript.startIndex, to: match.lowerBound)
            start = min(max(0, center - transcriptWindowLength / 2), total - transcriptWindowLength)
        }
        let lower = transcript.index(transcript.startIndex, offsetBy: start)
        let upper = transcript.index(lower, offsetBy: transcriptWindowLength)
        return String(transcript[lower..<upper])
    }
}
