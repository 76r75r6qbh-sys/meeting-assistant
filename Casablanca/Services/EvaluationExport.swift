import Foundation

/// Builds the `casablanca.eval-export` v1 document for one meeting: the
/// JSON that `tools/eval/casaeval.py` scores against a hand-made gold file.
///
/// Pure: reads the meeting, never writes it. Every key is always present;
/// absent values are encoded as `null` or `[]`, never omitted.
///
/// `actionItemsSource`:
/// - `"structured"`: the items stored on the meeting (`Meeting.actionItems`).
///   That includes items the summarizer stored from its own markdown fallback
///   (confidence `0.5`, quote `null`); "structured" means "stored", not
///   "came from structured LLM output".
/// - `"summaryMarkdown"`: nothing stored, so the items were parsed here from
///   the summary's action-item bullets (confidence `0`, `verified: "unverified"`).
/// - `"none"`: neither; `actionItems` is `[]`.
enum EvaluationExport {

    static let schemaName = "casablanca.eval-export"
    static let schemaVersion = 1

    static let topLevelKeys: Set<String> = [
        "schema", "schemaVersion", "exportedAt", "appVersion", "meeting", "speakers",
        "transcript", "summary", "actionItemsSource", "actionItems", "decisions",
    ]

    /// Value of `DecisionInfo.source` for decisions parsed from the summary.
    static let summaryMarkdownSource = "summaryMarkdown"

    // MARK: - Document

    struct Document: Codable, Equatable {
        var schema: String
        var schemaVersion: Int
        var exportedAt: Date
        var appVersion: String
        var meeting: MeetingInfo
        var speakers: [SpeakerInfo]
        var transcript: TranscriptInfo
        var summary: SummaryInfo
        var actionItemsSource: ActionItemsSource
        var actionItems: [ActionItemInfo]
        var decisions: [DecisionInfo]
    }

    enum ActionItemsSource: String, Codable {
        case structured, summaryMarkdown, none
    }

    struct MeetingInfo: Codable, Equatable {
        var id: String
        var title: String
        var date: Date
        var endDate: Date?
        var durationSeconds: Double?
        var language: String
        var participants: [String]
        var tags: [String]
        var summaryTemplateID: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(date, forKey: .date)
            try c.encodeOrNull(endDate, forKey: .endDate)
            try c.encodeOrNull(durationSeconds, forKey: .durationSeconds)
            try c.encode(language, forKey: .language)
            try c.encode(participants, forKey: .participants)
            try c.encode(tags, forKey: .tags)
            try c.encodeOrNull(summaryTemplateID, forKey: .summaryTemplateID)
        }
    }

    struct TranscriptInfo: Codable, Equatable {
        var text: String?
        var lines: [LineInfo]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeOrNull(text, forKey: .text)
            try c.encode(lines, forKey: .lines)
        }
    }

    struct LineInfo: Codable, Equatable {
        var label: String
        var seconds: Double
        var speaker: String?
        var text: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            try c.encode(seconds, forKey: .seconds)
            try c.encodeOrNull(speaker, forKey: .speaker)
            try c.encode(text, forKey: .text)
        }
    }

    struct SummaryInfo: Codable, Equatable {
        var markdown: String?
        var decisions: [String]
        var actionItemTexts: [String]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeOrNull(markdown, forKey: .markdown)
            try c.encode(decisions, forKey: .decisions)
            try c.encode(actionItemTexts, forKey: .actionItemTexts)
        }
    }

    struct DecisionInfo: Codable, Equatable {
        var text: String
        var source: String
    }

    /// Export-local mirror of ``ExtractedActionItem`` whose `nil` fields are
    /// encoded as `null` (the shared type's synthesized encoding omits them).
    struct ActionItemInfo: Codable, Equatable {
        var task: String
        var owner: String?
        var due: String?
        var dueIsExplicit: Bool
        var confidence: Double
        var quote: String?
        var timestamp: String?
        var verified: VerificationState
        var verificationReason: String?

        init(_ item: ExtractedActionItem) {
            task = item.task
            owner = item.owner
            due = item.due
            dueIsExplicit = item.dueIsExplicit
            confidence = item.confidence
            quote = item.quote
            timestamp = item.timestamp
            verified = item.verified
            verificationReason = item.verificationReason
        }

        var extractedActionItem: ExtractedActionItem {
            ExtractedActionItem(
                task: task, owner: owner, due: due, dueIsExplicit: dueIsExplicit,
                confidence: confidence, quote: quote, timestamp: timestamp,
                verified: verified, verificationReason: verificationReason
            )
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(task, forKey: .task)
            try c.encodeOrNull(owner, forKey: .owner)
            try c.encodeOrNull(due, forKey: .due)
            try c.encode(dueIsExplicit, forKey: .dueIsExplicit)
            try c.encode(confidence, forKey: .confidence)
            try c.encodeOrNull(quote, forKey: .quote)
            try c.encodeOrNull(timestamp, forKey: .timestamp)
            try c.encode(verified, forKey: .verified)
            try c.encodeOrNull(verificationReason, forKey: .verificationReason)
        }
    }

    // MARK: - Building

    static func document(for meeting: Meeting, exportedAt: Date, appVersion: String) -> Document {
        let speakers = meeting.speakers
        let parsedSummary = meeting.summary.map(SummaryResponseParser.parse)

        let structured = meeting.actionItems
        let fallback = meeting.summary.map(fallbackActionItems(fromSummary:)) ?? []
        let source: ActionItemsSource
        let items: [ExtractedActionItem]
        if !structured.isEmpty {
            source = .structured
            items = structured
        } else if !fallback.isEmpty {
            source = .summaryMarkdown
            items = fallback
        } else {
            source = .none
            items = []
        }

        let decisions = parsedSummary?.decisions ?? []

        return Document(
            schema: schemaName,
            schemaVersion: schemaVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            meeting: MeetingInfo(
                id: meeting.id.uuidString,
                title: meeting.title,
                date: meeting.date,
                endDate: meeting.endDate,
                durationSeconds: meeting.recordingDuration,
                language: meeting.transcriptionLanguage,
                participants: meeting.participants,
                tags: meeting.tags,
                summaryTemplateID: meeting.summaryTemplateID
            ),
            speakers: speakers,
            transcript: TranscriptInfo(
                text: meeting.transcript,
                lines: transcriptLines(meeting.transcript, knownSpeakers: Set(speakers.map(\.displayName)))
            ),
            summary: SummaryInfo(
                markdown: meeting.summary,
                decisions: decisions,
                actionItemTexts: parsedSummary?.todoTexts ?? []
            ),
            actionItemsSource: source,
            actionItems: items.map(ActionItemInfo.init),
            decisions: decisions.map { DecisionInfo(text: $0, source: summaryMarkdownSource) }
        )
    }

    /// Pretty-printed, sorted keys, unescaped slashes, ISO 8601 UTC dates.
    static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    /// Action items parsed from a summary's action-item section (any
    /// ``SummaryResponseParser`` alias), for meetings without stored items.
    /// Each bullet `**owner** — task (yyyy-MM-dd) [mm:ss]` yields task and
    /// owner via ``ActionItemOwnership/parse(_:)``; a trailing `[mm:ss]` /
    /// `[h:mm:ss]` becomes `timestamp` and a trailing `(yyyy-MM-dd)` is
    /// removed (`due` stays `nil` per the export contract). Bullets with no
    /// task text left are dropped.
    static func fallbackActionItems(fromSummary summary: String) -> [ExtractedActionItem] {
        SummaryResponseParser.parse(summary).todoTexts.compactMap { bullet in
            let parsed = ActionItemOwnership.parse(bullet)
            var task = parsed.action
            let timestamp = removeTrailingMatch(trailingTimestampRegex, from: &task)
            _ = removeTrailingMatch(trailingDueDateRegex, from: &task)
            task = task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            return ExtractedActionItem(
                task: task, owner: parsed.owner, due: nil, dueIsExplicit: false,
                confidence: 0, quote: nil, timestamp: timestamp,
                verified: .unverified, verificationReason: nil
            )
        }
    }

    /// `<yyyy-MM-dd> <sanitized title>.eval.json`.
    static func suggestedFileName(for meeting: Meeting) -> String {
        "\(Meeting.obsidianDateString(from: meeting.date)) \(meeting.sanitizedTitle).eval.json"
    }

    // MARK: - Helpers

    private static let trailingTimestampRegex = try! NSRegularExpression(
        pattern: #"\s*\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s*$"#
    )

    private static let trailingDueDateRegex = try! NSRegularExpression(
        pattern: #"\s*\((\d{4}-\d{2}-\d{2})\)\s*$"#
    )

    /// Removes `regex`'s match from the end of `text`; returns capture group 1.
    private static func removeTrailingMatch(_ regex: NSRegularExpression, from text: inout String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let whole = Range(match.range, in: text),
              let group = Range(match.range(at: 1), in: text)
        else { return nil }
        let captured = String(text[group])
        text.removeSubrange(whole)
        return captured
    }

    /// Lines with a leading `[ts]`, parsed with the meeting's speaker names.
    /// Splits on the `\n` scalar and drops a trailing `\r`, so CRLF works.
    private static func transcriptLines(_ transcript: String?, knownSpeakers: Set<String>) -> [LineInfo] {
        guard let transcript else { return [] }
        return transcript.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { scalars -> LineInfo? in
                var line = String(String.UnicodeScalarView(scalars))
                if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
                guard let parsed = TranscriptLineFormat.parse(line, knownSpeakers: knownSpeakers) else { return nil }
                return LineInfo(label: parsed.label, seconds: parsed.seconds, speaker: parsed.speaker, text: parsed.text)
            }
    }
}

private extension KeyedEncodingContainer {
    /// Encodes `value`, or an explicit `null` when it is `nil`.
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
