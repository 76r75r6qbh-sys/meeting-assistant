import Foundation
import SwiftData

/// Plain-value copy of the parts of a ``Meeting`` that the cross-meeting
/// "Ask" feature searches. Value type and `Sendable`, so a corpus can be
/// built from a fetch on a background `ModelContext` (in batches via
/// ``AskCorpus/load(from:limit:offset:isPendingDeletion:)``) and handed to
/// the index without touching SwiftData objects on the main actor.
struct AskMeetingSnapshot: Equatable, Sendable {
    let id: UUID
    let title: String
    let date: Date
    let participants: [String]
    /// As stored on the meeting: already normalized (lowercased, trimmed).
    let tags: [String]
    let summary: String?
    let actionItems: [ExtractedActionItem]
    let transcript: String?
}

extension AskMeetingSnapshot {
    /// Copies the meeting's values. Call it on the actor that owns the
    /// meeting's `ModelContext` (the main actor for the view context, or a
    /// background actor for a context created there).
    init(meeting: Meeting) {
        self.init(
            id: meeting.id,
            title: meeting.title,
            date: meeting.date,
            participants: meeting.participants,
            tags: meeting.tags,
            summary: meeting.summary,
            actionItems: meeting.actionItems,
            transcript: meeting.transcript
        )
    }
}

enum AskChunkKind: String, Equatable, Sendable {
    case summary, actionItem, transcript
}

/// One retrievable piece of a meeting.
struct AskChunk: Identifiable, Equatable, Sendable {
    /// `"<meeting uuid>#<kind>#<n>"`, `n` 0-based per kind. Stable for the
    /// same snapshot.
    let id: String
    let meetingID: UUID
    let kind: AskChunkKind
    let text: String
    /// Transcript time label (`mm:ss` or `h:mm:ss`), or `nil` when the chunk
    /// has no time (summary sections, action items without a timestamp).
    let timeLabel: String?
}

/// Restricts which meetings the Ask feature searches. All set criteria must
/// hold. An empty or whitespace-only `participant` / `tag` counts as unset.
struct AskFilter: Equatable, Sendable {
    var from: Date?
    var to: Date?
    var participant: String?
    var tag: String?

    static let none = AskFilter()

    var isEmpty: Bool {
        from == nil && to == nil && Self.criterion(participant) == nil && Self.criterion(tag) == nil
    }

    /// `from` matches from the start of its day; `to` matches through the
    /// end of its day; participant matches any participant whose folded name
    /// contains the folded filter text; tag matches a stored tag exactly
    /// after normalizing the filter tag.
    func matches(_ m: AskMeetingSnapshot, calendar: Calendar = .current) -> Bool {
        if let from, m.date < calendar.startOfDay(for: from) {
            return false
        }
        if let to {
            let startOfTo = calendar.startOfDay(for: to)
            let endOfTo = calendar.date(byAdding: .day, value: 1, to: startOfTo) ?? startOfTo
            if m.date >= endOfTo { return false }
        }
        if let participant = Self.criterion(participant) {
            let needle = AskTokenizer.fold(participant)
            guard m.participants.contains(where: { AskTokenizer.fold($0).contains(needle) }) else {
                return false
            }
        }
        if let raw = Self.criterion(tag), let tag = Meeting.normalizeTag(raw) {
            guard m.tags.contains(tag) else { return false }
        }
        return true
    }

    private static func criterion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Builds the Ask corpus: meeting snapshots, their chunks and the filter
/// options. Pure apart from ``load(from:limit:offset:isPendingDeletion:)``,
/// which only reads the given context; none of it is main-actor bound.
enum AskCorpus {
    static let transcriptChunkTokens = 220
    static let transcriptOverlapTokens = 40
    static let summarySectionMaxChars = 1_200

    // MARK: - Chunks

    /// Summary sections, then structured action items, then transcript
    /// chunks. A meeting with neither summary nor transcript yields `[]`.
    static func chunks(for m: AskMeetingSnapshot) -> [AskChunk] {
        let summary = nonBlank(m.summary)
        let transcript = nonBlank(m.transcript)
        guard summary != nil || transcript != nil else { return [] }

        var result: [AskChunk] = []
        func id(_ kind: AskChunkKind, _ n: Int) -> String { "\(m.id.uuidString)#\(kind.rawValue)#\(n)" }

        if let summary {
            for (n, text) in summarySections(summary).enumerated() {
                result.append(AskChunk(id: id(.summary, n), meetingID: m.id, kind: .summary, text: text, timeLabel: nil))
            }
        }
        for (n, item) in m.actionItems.enumerated() {
            result.append(AskChunk(
                id: id(.actionItem, n), meetingID: m.id, kind: .actionItem,
                text: actionItemText(item), timeLabel: nonBlank(item.timestamp)
            ))
        }
        if let transcript {
            let pieces = TranscriptChunker.chunks(
                of: transcript, chunkTokens: transcriptChunkTokens, overlapTokens: transcriptOverlapTokens
            )
            for piece in pieces {
                result.append(AskChunk(
                    id: id(.transcript, piece.index), meetingID: m.id, kind: .transcript,
                    text: piece.text, timeLabel: piece.startLabel
                ))
            }
        }
        return result
    }

    /// `Action item: <task> — owner: <owner | unassigned>[ — due <due>][ — "<quote>"]`
    static func actionItemText(_ item: ExtractedActionItem) -> String {
        var text = "Action item: \(item.task.trimmingCharacters(in: .whitespacesAndNewlines))"
        text += " — owner: \(nonBlank(item.owner) ?? "unassigned")"
        if let due = nonBlank(item.due) { text += " — due \(due)" }
        if let quote = nonBlank(item.quote) { text += " — \"\(quote)\"" }
        return text
    }

    /// Splits at lines starting with `## ` (the text before the first header
    /// is its own section), then splits any section longer than
    /// ``summarySectionMaxChars`` on blank lines; a single paragraph that is
    /// still too long is cut at whitespace.
    static func summarySections(_ summary: String) -> [String] {
        var sections: [[String]] = [[]]
        for line in summary.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") && !(sections.last?.isEmpty ?? true) {
                sections.append([line])
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        return sections
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap(limitSection)
    }

    // MARK: - Load

    /// Fetches up to `limit` meetings (newest first, starting at `offset`)
    /// and returns snapshots of the searchable ones: skips ids for which
    /// `isPendingDeletion` is true, upcoming and recording meetings, and
    /// meetings with neither summary nor transcript. Works on any context,
    /// so callers can run it on a background `ModelContext` in batches.
    static func load(
        from context: ModelContext,
        limit: Int = 1_000,
        offset: Int = 0,
        isPendingDeletion: (UUID) -> Bool
    ) throws -> [AskMeetingSnapshot] {
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = max(0, limit)
        descriptor.fetchOffset = max(0, offset)
        return try context.fetch(descriptor).compactMap { meeting in
            switch meeting.status {
            case .upcoming, .recording, .pausedRecording:
                return nil
            case .notesOnly, .processing, .completed:
                break
            }
            guard !isPendingDeletion(meeting.id) else { return nil }
            guard nonBlank(meeting.summary) != nil || nonBlank(meeting.transcript) != nil else { return nil }
            return AskMeetingSnapshot(meeting: meeting)
        }
    }

    // MARK: - Filter options

    /// Distinct non-empty participants and tags, each sorted with
    /// `localizedStandardCompare`.
    static func filterOptions(_ snapshots: [AskMeetingSnapshot]) -> (participants: [String], tags: [String]) {
        (distinctSorted(snapshots.flatMap(\.participants)), distinctSorted(snapshots.flatMap(\.tags)))
    }

    // MARK: - Private

    private static func distinctSorted(_ values: [String]) -> [String] {
        let distinct = Set(values.compactMap(nonBlank))
        return distinct.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func limitSection(_ section: String) -> [String] {
        let limit = summarySectionMaxChars
        guard section.count > limit else { return [section] }

        let paragraphs = section
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { hardSplit($0, limit: limit) }

        var pieces: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= limit {
                current += "\n\n" + paragraph
            } else {
                pieces.append(current)
                current = paragraph
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Cuts text longer than `limit` characters at the last whitespace in
    /// each window (or mid-word when a window has none).
    private static func hardSplit(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: \.isWhitespace).flatMap { $0 > window.startIndex ? $0 : nil }
                ?? window.endIndex
            let piece = rest[rest.startIndex..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...].drop(while: \.isWhitespace)
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
