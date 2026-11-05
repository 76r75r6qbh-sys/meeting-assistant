// Casablanca/Services/SummaryFacts.swift
import Foundation

// MARK: - Types

/// One decision as extracted from a meeting, with its supporting quote.
struct ExtractedDecision: Codable, Equatable {
    var text: String
    var quote: String?
    /// Transcript timestamp label of the quote (`mm:ss` or `h:mm:ss`).
    var timestamp: String?
    var verified: VerificationState = .unverified
    var verificationReason: String?

    init(text: String, quote: String? = nil, timestamp: String? = nil,
         verified: VerificationState = .unverified, verificationReason: String? = nil) {
        self.text = text
        self.quote = quote
        self.timestamp = timestamp
        self.verified = verified
        self.verificationReason = verificationReason
    }

    /// Tolerant of stored rows written before `verified` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        verified = (try? c.decodeIfPresent(VerificationState.self, forKey: .verified)) ?? .unverified
        verificationReason = try c.decodeIfPresent(String.self, forKey: .verificationReason)
    }
}

/// An open question, risk, notable statement or figure.
struct ExtractedNote: Codable, Equatable {
    var text: String
    var timestamp: String?
}

/// The structured content of a meeting summary: what the JSON block of a
/// summary response carries, or what the markdown fallback could recover.
struct SummaryFacts: Equatable {
    var topics: [String]
    var decisions: [ExtractedDecision]
    var actionItems: [ExtractedActionItem]
    var openQuestions: [ExtractedNote]
    var facts: [ExtractedNote]

    static let empty = SummaryFacts(topics: [], decisions: [], actionItems: [], openQuestions: [], facts: [])

    // MARK: Merging

    /// Concatenates `parts` in order. Action items whose tasks are fuzzy
    /// duplicates (``FuzzyText/isFuzzyEqual(_:_:)``) collapse into the one with the
    /// higher confidence (the earlier one on a tie), which takes the other's
    /// owner/due/quote/timestamp where its own is nil. Decisions collapse the
    /// same way on `text` (earlier wins). Topics are de-duplicated on their
    /// normalized form; questions and facts are concatenated.
    static func merged(_ parts: [SummaryFacts]) -> SummaryFacts {
        var result = SummaryFacts.empty
        var topicKeys = Set<String>()
        for part in parts {
            for topic in part.topics {
                let key = FuzzyText.normalized(topic)
                guard !key.isEmpty, topicKeys.insert(key).inserted else { continue }
                result.topics.append(topic)
            }
            for item in part.actionItems {
                if let i = result.actionItems.firstIndex(where: {
                    FuzzyText.isFuzzyEqual($0.task, item.task)
                }) {
                    result.actionItems[i] = combine(result.actionItems[i], item)
                } else {
                    result.actionItems.append(item)
                }
            }
            for decision in part.decisions {
                if let i = result.decisions.firstIndex(where: {
                    FuzzyText.isFuzzyEqual($0.text, decision.text)
                }) {
                    var kept = result.decisions[i]
                    kept.quote = kept.quote ?? decision.quote
                    kept.timestamp = kept.timestamp ?? decision.timestamp
                    result.decisions[i] = kept
                } else {
                    result.decisions.append(decision)
                }
            }
            result.openQuestions += part.openQuestions
            result.facts += part.facts
        }
        return result
    }

    private static func combine(_ existing: ExtractedActionItem, _ incoming: ExtractedActionItem) -> ExtractedActionItem {
        var winner = incoming.confidence > existing.confidence ? incoming : existing
        let other = incoming.confidence > existing.confidence ? existing : incoming
        winner.owner = winner.owner ?? other.owner
        if winner.due == nil, let due = other.due {
            winner.due = due
            winner.dueIsExplicit = other.dueIsExplicit
        }
        winner.quote = winner.quote ?? other.quote
        winner.timestamp = winner.timestamp ?? other.timestamp
        return winner
    }

    // MARK: Markdown fallback

    /// Facts recovered from a markdown-only summary: action items from the
    /// Action Items section (`**owner** — action`), decisions from Decisions.
    static func fromMarkdown(_ parsed: SummaryResponseParser.ParsedResponse) -> SummaryFacts {
        var facts = SummaryFacts.empty
        for line in parsed.todoTexts {
            let item = ActionItemOwnership.parse(line)
            guard !item.action.isEmpty else { continue }
            facts.actionItems.append(ExtractedActionItem(
                task: item.action, owner: sanitizedOwner(item.owner), due: nil, dueIsExplicit: false,
                confidence: 0.5, quote: nil, timestamp: nil, verified: .unverified, verificationReason: nil))
        }
        for text in parsed.decisions {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            facts.decisions.append(ExtractedDecision(text: trimmed))
        }
        return facts
    }

    // MARK: Owners

    /// Generic speaker labels and pronouns that never name an owner.
    private static let nonOwnerWords: Set<String> = ["others", "anderen", "me", "ik", "i", "unknown speaker", "null"]

    /// `raw` trimmed and stripped of `*`, or `nil` when it is empty, an
    /// "unassigned" word, or a generic label (`Speaker 1`, `Spreker 2`,
    /// `Others`, `Anderen`, `me`, `ik`, …).
    static func sanitizedOwner(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let folded = ActionItemOwnership.fold(cleaned)
        if ActionItemOwnership.unassignedOwners.contains(folded) || nonOwnerWords.contains(folded) { return nil }
        // Diarization labels: "Speaker 1", "Spreker B", "speaker_2", "S1".
        if folded.range(of: #"^(speaker|spreker|sprecher)[\s_-]*(\d+|[a-z])$"#, options: .regularExpression) != nil { return nil }
        if folded.range(of: #"^s[\s_-]*\d+$"#, options: .regularExpression) != nil { return nil }
        return cleaned
    }

    // MARK: Rendering

    /// Compact notes for prompts (merge/verification input). Sections without
    /// items are left out; `[ts] ` only where a timestamp exists.
    func notesMarkdown() -> String {
        func prefix(_ ts: String?) -> String { ts.map { "[\($0)] " } ?? "" }
        var lines: [String] = []
        func section(_ heading: String, _ rows: [String]) {
            guard !rows.isEmpty else { return }
            lines.append(heading)
            lines += rows.map { "- " + $0 }
        }
        section("### Topics discussed", topics)
        section("### Decisions", decisions.map { prefix($0.timestamp) + $0.text })
        section("### Action items (owner: what)", actionItems.map { item in
            prefix(item.timestamp) + "\(item.owner ?? "?"): \(item.task)" + (item.due.map { " (\($0))" } ?? "")
        })
        section("### Open questions and risks", openQuestions.map { prefix($0.timestamp) + $0.text })
        section("### Notable statements and figures", facts.map { prefix($0.timestamp) + $0.text })
        return lines.joined(separator: "\n")
    }
}

// MARK: - Parser

/// Splits a single-pass summary response into markdown and its JSON block, and
/// decodes the JSON leniently (cross-track ruling R11: never through
/// `ExtractedActionItem`'s synthesized `Decodable`; missing fields get
/// defaults and only invalid items are dropped).
enum SummaryFactsParser {
    enum Failure: Error, Equatable { case noJSON, invalidJSON }

    struct SinglePassSplit: Equatable {
        let markdown: String
        let jsonText: String?
    }

    // MARK: Splitting

    /// Removes the last fenced block tagged `json` (or an untagged block whose
    /// content starts with `{`), with the whitespace before it, from the
    /// response. An unclosed trailing ```` ```json ```` block (a truncated
    /// response) counts as a block running to the end.
    static func splitSinglePass(_ response: String) -> SinglePassSplit {
        let ns = response as NSString
        var chosen: (range: NSRange, content: String)?
        var lastEnd = 0
        if let fence = try? NSRegularExpression(pattern: "```([A-Za-z0-9_+-]*)(.*?)```", options: [.dotMatchesLineSeparators]) {
            for match in fence.matches(in: response, range: NSRange(location: 0, length: ns.length)) {
                lastEnd = match.range.location + match.range.length
                let info = ns.substring(with: match.range(at: 1)).lowercased()
                let content = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if info == "json" || (info.isEmpty && content.hasPrefix("{")) {
                    chosen = (match.range, content)
                }
            }
        }
        let tail = NSRange(location: lastEnd, length: ns.length - lastEnd)
        if let open = try? NSRegularExpression(pattern: "```json(.*)\\z", options: [.dotMatchesLineSeparators, .caseInsensitive]),
           let match = open.firstMatch(in: response, range: tail) {
            chosen = (match.range, ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let chosen else {
            return SinglePassSplit(markdown: response.trimmingCharacters(in: .whitespacesAndNewlines), jsonText: nil)
        }
        var start = chosen.range.location
        while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start -= 1
        }
        let end = chosen.range.location + chosen.range.length
        let markdown = ns.substring(to: start) + ns.substring(from: end)
        return SinglePassSplit(markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
                               jsonText: chosen.content)
    }

    /// Strips one surrounding code fence, then returns the text from the first
    /// `{` to the last `}`; `nil` when there is no such span.
    static func extractJSONObject(_ text: String) -> String? {
        extractJSON(text, open: "{", close: "}")
    }

    /// As ``extractJSONObject(_:)``, to the last `]`, from the first `[` that
    /// is followed (after optional whitespace) by `{` — so a `[00:30]` in
    /// prose before the array is skipped — else from the first `[`.
    static func extractJSONArray(_ text: String) -> String? {
        extractJSON(text, open: "[", close: "]", preferOpenBefore: "{")
    }

    private static func extractJSON(_ text: String, open: Character, close: Character,
                                    preferOpenBefore next: Character? = nil) -> String? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            if let newline = body.firstIndex(of: "\n") {
                body = String(body[body.index(after: newline)...])
            } else {
                body = String(body.dropFirst(3).drop(while: { $0.isLetter }))
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
        }
        let preferred = next.flatMap { next in
            body.indices.first { index in
                body[index] == open && body[body.index(after: index)...].first { !$0.isWhitespace } == next
            }
        }
        guard let first = preferred ?? body.firstIndex(of: open), let last = body.lastIndex(of: close),
              first < last else { return nil }
        return String(body[first...last])
    }

    // MARK: Decoding

    static func decodeFacts(_ jsonText: String, meetingDate: Date, calendar: Calendar) -> Result<SummaryFacts, Failure> {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noJSON) }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = object as? [String: Any]
        else { return .failure(.invalidJSON) }

        var facts = SummaryFacts.empty
        facts.topics = list(root["topics"]).compactMap { entry in
            text(entry) ?? (entry as? [String: Any]).flatMap { text($0["text"]) ?? text($0["topic"]) }
        }
        facts.decisions = list(root["decisions"]).compactMap { entry in
            if let plain = text(entry) { return ExtractedDecision(text: plain) }
            guard let dict = entry as? [String: Any], let body = text(dict["text"]) else { return nil }
            return ExtractedDecision(text: body, quote: text(dict["quote"]), timestamp: timestamp(dict["timestamp"]))
        }
        facts.actionItems = list(root["action_items"]).compactMap { entry in
            guard let dict = entry as? [String: Any], let task = text(dict["task"]) else { return nil }
            let due = RelativeDateResolver.resolve(text(dict["due"]), llmSaysExplicit: bool(dict["due_is_explicit"]),
                                                   meetingDate: meetingDate, calendar: calendar)
            return ExtractedActionItem(
                task: task, owner: SummaryFacts.sanitizedOwner(text(dict["owner"])),
                due: due.iso, dueIsExplicit: due.isExplicit, confidence: confidence(dict["confidence"]),
                quote: text(dict["quote"]), timestamp: timestamp(dict["timestamp"]),
                verified: .unverified, verificationReason: nil)
        }
        facts.openQuestions = notes(root["open_questions"])
        facts.facts = notes(root["facts"])
        return .success(facts)
    }

    // MARK: Lenient field readers

    private static func list(_ value: Any?) -> [Any] { value as? [Any] ?? [] }

    private static func notes(_ value: Any?) -> [ExtractedNote] {
        list(value).compactMap { entry in
            if let plain = text(entry) { return ExtractedNote(text: plain, timestamp: nil) }
            guard let dict = entry as? [String: Any], let body = text(dict["text"]) else { return nil }
            return ExtractedNote(text: body, timestamp: timestamp(dict["timestamp"]))
        }
    }

    /// A non-empty trimmed string, else `nil` (null, numbers, objects, "").
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "yes", "ja"].contains(string.lowercased().trimmingCharacters(in: .whitespaces)) }
        return false
    }

    /// A number, a numeric string ("0.7", "0,7") or high/medium/low; default
    /// 0.5. Values above 1 up to 100 are percentages (80 → 0.8); anything
    /// else is clamped to 0…1.
    private static func confidence(_ value: Any?) -> Double {
        var result = 0.5
        if let number = value as? NSNumber, !isBoolean(number) {
            result = number.doubleValue
        } else if let string = text(value) {
            switch ActionItemOwnership.fold(string) {
            case "high", "hoog": result = 0.9
            case "medium", "middel", "gemiddeld": result = 0.6
            case "low", "laag": result = 0.3
            case let other: result = Double(other.replacingOccurrences(of: ",", with: ".")) ?? 0.5
            }
        }
        guard result.isFinite else { return 0.5 }
        if result > 1, result <= 100 { result /= 100 }
        return min(max(result, 0), 1)
    }

    /// Brackets stripped; kept (re-labelled canonically) only when it parses.
    private static func timestamp(_ value: Any?) -> String? {
        guard let raw = text(value) else { return nil }
        let label = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
        guard let seconds = TranscriptLineFormat.seconds(fromLabel: label) else { return nil }
        return TranscriptLineFormat.timestampLabel(seconds: seconds)
    }
}

// MARK: - Prompt copy

enum SummaryFactsPrompt {
    static let objectShape = #"""
    {
      "topics": ["<short topic>"],
      "decisions": [{"text": "<decision with its rationale>", "quote": "<verbatim words from the transcript>", "timestamp": "<mm:ss or h:mm:ss>"}],
      "action_items": [{"task": "<the action>", "owner": "<name or null>", "due": "<YYYY-MM-DD, or the words used such as \"vrijdag\", or null>", "due_is_explicit": true, "confidence": 0.8, "quote": "<verbatim words from the transcript>", "timestamp": "<mm:ss or h:mm:ss>"}],
      "open_questions": [{"text": "<question or risk>", "timestamp": "<mm:ss or h:mm:ss>"}],
      "facts": [{"text": "<notable statement or figure>", "timestamp": "<mm:ss or h:mm:ss>"}]
    }
    """#

    static func rules(meetingDate: Date, calendar: Calendar) -> String {
        let (date, weekday) = dateAndWeekday(meetingDate, calendar)
        return """
        Rules for the JSON:
        - Text values are in the language of the transcript; keys stay in English. Use [] for an empty list and never leave out a key.
        - "quote" is copied word for word from the transcript (at most 25 words), without the [timestamp] and without the speaker label. Use null when the item comes from the user's notes rather than the transcript.
        - "timestamp" is the [timestamp] of the transcript line the quote comes from, without brackets; null if unknown.
        - Set "owner" only on explicit evidence: a named assignment ("Kim, wil jij…"), a first-person commitment by a labelled speaker ("Youri: ik pak dat op" makes Youri the owner), a commitment by the note-taker, or the user's own notes. Otherwise "owner" is null. Never use "me", "I" or a generic label such as "Speaker 1", "Spreker 2", "Others" or "Anderen" as an owner.
        - The meeting took place on \(date) (\(weekday)). Write "due" as YYYY-MM-DD when you can resolve it from that date, otherwise the words that were used. "due_is_explicit" is true only when a specific day or date was said.
        - "confidence" (0.0-1.0) is how sure you are that this was really agreed as an action.
        """
    }

    static func singlePassInstruction(meetingDate: Date, calendar: Calendar) -> String {
        "After the notes, add one fenced code block that starts with ```json and contains one valid JSON object with exactly this shape. Write nothing after the closing ```."
            + "\n" + objectShape
            + "\n" + rules(meetingDate: meetingDate, calendar: calendar)
            + "\n- Every action item and decision in the notes appears in the JSON, and nothing else does."
    }

    static func repairPrompt(broken: String) -> String {
        """
        The text below was meant to be one JSON object with this shape, but it is not valid JSON:
        \(objectShape)
        Return only the corrected JSON object — no prose and no code fence. Keep every item and every value; do not add items.

        Text:
        \(broken)
        """
    }

    /// For a single pass that returned no JSON at all. `closingSections` is the
    /// markdown's Decisions + Action Items sections only, never the transcript.
    static func rebuildPrompt(fromMarkdown closingSections: String, meetingDate: Date, calendar: Calendar) -> String {
        """
        These are the closing sections of meeting notes. Turn them into one JSON object with exactly this shape:
        \(objectShape)
        \(rules(meetingDate: meetingDate, calendar: calendar))
        Use null for "quote" and "timestamp" unless the notes show them. Return only the JSON object — no prose and no code fence.

        Notes:
        \(closingSections)
        """
    }

    /// `yyyy-MM-dd` and the English weekday name of `date` in `calendar`'s time zone.
    private static func dateAndWeekday(_ date: Date, _ calendar: Calendar) -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let iso = formatter.string(from: date)
        formatter.dateFormat = "EEEE"
        return (iso, formatter.string(from: date))
    }
}
