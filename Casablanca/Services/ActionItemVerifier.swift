// Casablanca/Services/ActionItemVerifier.swift
import Foundation

// MARK: - Transcript index

/// A parsed transcript prepared for quote lookups: the timestamped lines, and
/// their normalised text as one token stream (speaker prefixes of known
/// speakers and timestamps removed) so a quote can span line boundaries.
struct TranscriptIndex {
    /// Timestamped lines in transcript order. A line without a leading `[ts]`
    /// is appended (after a space) to the previous line's text; untimed text
    /// before the first timestamped line goes into a synthetic `00:00` line,
    /// so a transcript without any timestamps is one synthetic line.
    let lines: [TranscriptLine]
    /// Whether `lines[0]` is the synthetic `00:00` line holding untimed lead-in text.
    let startsWithSyntheticLine: Bool

    /// The normalised line texts joined by single spaces, with a leading and a
    /// trailing space so whole-word searches can match `" " + needle + " "`
    /// (bridged once, so repeated searches do not re-bridge a long transcript).
    private let haystack: NSString

    /// UTF-16 offset in `haystack` where each non-empty line starts, ascending,
    /// paired with the index of that line in `lines`.
    private let lineStarts: [(offset: Int, line: Int)]
    /// All normalised tokens of the transcript, in order.
    private let tokens: [String]
    /// For each token: the index in `lines` of the line it belongs to.
    private let tokenLine: [Int]
    /// Prefix sums of token lengths in characters (`tokenLengthSums[i]` = sum of the first `i`).
    private let tokenLengthSums: [Int]
    /// For each line: its range in `tokens`.
    private let lineTokens: [Range<Int>]
    /// Token → every position where it occurs.
    private let positions: [String: [Int]]
    /// Each token's characters as dense alphabet codes (see `alphabet`).
    private let tokenCodes: [[Int]]
    /// Character → dense code, over every character of the normalised
    /// transcript plus the space (code 0). Character equality, so the scores
    /// equal ``FuzzyText/similarity(_:_:)`` on the same normalised text.
    private let alphabet: [Character: Int]

    init(transcript: String, knownSpeakers: Set<String>) {
        var parsed: [TranscriptLine] = []
        var synthetic = false
        // Split on the scalar so CRLF transcripts still split into lines.
        for scalars in transcript.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var raw = String(String.UnicodeScalarView(scalars))
            if raw.unicodeScalars.last == "\r" { raw.unicodeScalars.removeLast() }
            if let line = TranscriptLineFormat.parse(raw, knownSpeakers: knownSpeakers) {
                parsed.append(line)
                continue
            }
            let continuation = raw.trimmingCharacters(in: .whitespaces)
            guard !continuation.isEmpty else { continue }
            if parsed.isEmpty {
                parsed.append(TranscriptLine(label: TranscriptLineFormat.timestampLabel(seconds: 0), seconds: 0,
                                             speaker: nil, text: ""))
                synthetic = true
            }
            let last = parsed.count - 1
            parsed[last].text = parsed[last].text.isEmpty ? continuation : parsed[last].text + " " + continuation
        }
        lines = parsed
        startsWithSyntheticLine = synthetic

        var haystack = " "
        var utf16Count = 1
        var lineStarts: [(offset: Int, line: Int)] = []
        var tokens: [String] = []
        var tokenLine: [Int] = []
        var sums = [0]
        var lineTokens: [Range<Int>] = []
        var positions: [String: [Int]] = [:]
        var tokenCodes: [[Int]] = []
        var alphabet: [Character: Int] = [" ": 0]
        for (lineIndex, line) in parsed.enumerated() {
            let normalized = FuzzyText.normalized(line.text)
            let first = tokens.count
            if !normalized.isEmpty {
                if utf16Count > 1 {
                    haystack.append(" ")
                    utf16Count += 1
                }
                lineStarts.append((utf16Count, lineIndex))
                haystack.append(normalized)
                utf16Count += normalized.utf16.count
                for token in normalized.split(separator: " ") {
                    let word = String(token)
                    positions[word, default: []].append(tokens.count)
                    tokens.append(word)
                    tokenLine.append(lineIndex)
                    sums.append(sums[sums.count - 1] + word.count)
                    tokenCodes.append(word.map { character in
                        if let code = alphabet[character] { return code }
                        let code = alphabet.count
                        alphabet[character] = code
                        return code
                    })
                }
            }
            lineTokens.append(first..<tokens.count)
        }
        self.haystack = (haystack + " ") as NSString
        self.lineStarts = lineStarts
        self.tokens = tokens
        self.tokenLine = tokenLine
        self.tokenLengthSums = sums
        self.lineTokens = lineTokens
        self.positions = positions
        self.tokenCodes = tokenCodes
        self.alphabet = alphabet
    }

    /// Whether `line` is the synthetic `00:00` line holding untimed lead-in text.
    func isSynthetic(_ line: TranscriptLine) -> Bool {
        startsWithSyntheticLine && line == lines[0]
    }

    /// Lines whose time is within `radius` seconds of `seconds` (inclusive), in order.
    func window(around seconds: Double, radius: Double) -> [TranscriptLine] {
        lines.filter { abs($0.seconds - seconds) <= radius }
    }

    /// How well `quote` occurs in the transcript and the line where the best
    /// match starts. An exact normalised whole-word match scores 1.0 (the
    /// occurrence nearest `seconds` wins; `pak` never matches inside `pakket`). Otherwise windows of `k−1…k+1` tokens (`k` =
    /// the quote's token count) are scored with ``FuzzyText/similarity(_:_:)``:
    /// first those starting in the ±``ActionItemVerifier/windowRadius`` s window
    /// around `seconds`, then — only if that stays below
    /// ``FuzzyText/matchThreshold`` — those anywhere whose first token equals
    /// one of the quote's first two tokens. `(0, nil)` for an empty quote.
    func locate(quote: String, near seconds: Double?) -> (score: Double, line: TranscriptLine?) {
        let needle = FuzzyText.normalized(quote)
        guard !needle.isEmpty, !tokens.isEmpty else { return (0, nil) }

        if let line = exactMatchLine(needle, near: seconds) { return (1.0, line) }

        let quoteTokens = needle.split(separator: " ").map(String.init)
        // Characters the transcript never contains get code -1: they match nothing.
        let quoteCodes = needle.map { alphabet[$0] ?? -1 }
        var best: (score: Double, start: Int?) = (0, nil)

        if let seconds {
            var starts: [Int] = []
            for (i, line) in lines.enumerated() where abs(line.seconds - seconds) <= ActionItemVerifier.windowRadius {
                starts.append(contentsOf: lineTokens[i])
            }
            scoreWindows(starting: starts, quoteCodes: quoteCodes, quoteTokenCount: quoteTokens.count, best: &best)
        }
        if best.score < FuzzyText.matchThreshold {
            var starts = Set<Int>()
            for token in quoteTokens.prefix(2) { starts.formUnion(positions[token] ?? []) }
            scoreWindows(starting: starts.sorted(), quoteCodes: quoteCodes, quoteTokenCount: quoteTokens.count,
                         best: &best)
        }
        guard let start = best.start else { return (best.score, nil) }
        return (best.score, lines[tokenLine[start]])
    }

    // MARK: Private

    /// The line holding the whole-word occurrence of `needle` nearest
    /// `seconds` (the first one when `seconds` is nil), or nil when there is none.
    private func exactMatchLine(_ needle: String, near seconds: Double?) -> TranscriptLine? {
        let padded = " " + needle + " "
        var found: TranscriptLine?
        var location = 0
        while location < haystack.length {
            let range = haystack.range(of: padded, options: .literal,
                                       range: NSRange(location: location, length: haystack.length - location))
            guard range.location != NSNotFound else { break }
            // The match starts at its leading space; the quote one character later.
            let line = lines[lineIndex(atUTF16Offset: range.location + 1)]
            guard let seconds else { return line }
            if found.map({ abs(line.seconds - seconds) < abs($0.seconds - seconds) }) ?? true {
                found = line
            }
            // The trailing space may be the leading space of the next occurrence.
            location = range.location + range.length - 1
        }
        return found
    }

    /// Index in `lines` of the line whose normalised text contains `offset`.
    private func lineIndex(atUTF16Offset offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid].offset <= offset { low = mid } else { high = mid - 1 }
        }
        return lineStarts[low].line
    }

    /// Scores every window of `k−1…k+1` tokens starting at `starts`, keeping
    /// the strictly best one in `best`. The score is
    /// ``FuzzyText/similarity(_:_:)`` — `1 − Levenshtein / longer length` over
    /// the normalised characters — computed on alphabet codes. A window whose
    /// length difference alone already rules out beating `best`
    /// (Levenshtein ≥ |len a − len b|) is skipped, so the result equals scoring
    /// them all.
    private func scoreWindows(starting starts: [Int], quoteCodes: [Int], quoteTokenCount k: Int,
                              best: inout (score: Double, start: Int?)) {
        let quoteLength = quoteCodes.count
        let distance = EditDistance(pattern: quoteCodes, alphabetSize: alphabet.count)
        let sizes = max(1, k - 1)...(k + 1)
        var window: [Int] = []
        for start in starts {
            for size in sizes {
                let end = start + size
                guard end <= tokens.count else { break }
                let length = tokenLengthSums[end] - tokenLengthSums[start] + (size - 1)
                let longest = max(length, quoteLength)
                let ceiling = 1 - Double(abs(length - quoteLength)) / Double(longest)
                guard ceiling > best.score else { continue }
                window.removeAll(keepingCapacity: true)
                for t in start..<end {
                    if t > start { window.append(0) }
                    window.append(contentsOf: tokenCodes[t])
                }
                let score = 1 - Double(distance.to(window)) / Double(longest)
                if score > best.score { best = (score, start) }
            }
        }
    }
}

/// Levenshtein distance from one fixed pattern to many texts, over dense
/// integer codes, with Myers' bit-parallel algorithm in Hyyrö's global
/// (whole-pattern-to-whole-text) form, blocked in 64-bit words so any
/// pattern length works. Exact: equals the two-row dynamic programme, at a
/// few word operations per text symbol and block.
private struct EditDistance {
    private let length: Int
    private let blocks: Int
    /// `peq[code * blocks + b]`: bit mask of pattern positions `64·b …` holding `code`.
    private let peq: [UInt64]
    /// Bit of the pattern's last position inside the last block.
    private let lastBit: UInt64

    init(pattern: [Int], alphabetSize: Int) {
        length = pattern.count
        blocks = max(1, (pattern.count + 63) / 64)
        var peq = [UInt64](repeating: 0, count: alphabetSize * blocks)
        for (i, code) in pattern.enumerated() where code >= 0 {
            peq[code * blocks + i / 64] |= 1 << UInt64(i % 64)
        }
        self.peq = peq
        lastBit = 1 << UInt64((max(pattern.count, 1) - 1) % 64)
    }

    func to(_ text: [Int]) -> Int {
        if length == 0 { return text.count }
        if text.isEmpty { return length }
        var pv = [UInt64](repeating: ~0, count: blocks)
        var mv = [UInt64](repeating: 0, count: blocks)
        var score = length
        for code in text {
            // The top row grows by one per text symbol: carry +1 into block 0.
            var carry = 1
            for b in 0..<blocks {
                var eq = peq[code * blocks + b]
                let xv = eq | mv[b]
                if carry < 0 { eq |= 1 }
                let xh = (((eq & pv[b]) &+ pv[b]) ^ pv[b]) | eq
                var ph = mv[b] | ~(xh | pv[b])
                var mh = pv[b] & xh
                let high: UInt64 = b == blocks - 1 ? lastBit : 1 << 63
                let out = ph & high != 0 ? 1 : (mh & high != 0 ? -1 : 0)
                ph <<= 1
                mh <<= 1
                if carry < 0 { mh |= 1 } else if carry > 0 { ph |= 1 }
                pv[b] = mh | ~(xv | ph)
                mv[b] = ph & xv
                carry = out
            }
            score += carry
        }
        return score
    }
}

// MARK: - Verifier

/// Checks extracted action items and decisions against the transcript. The
/// deterministic pre-check runs first: a quote that does not occur in the
/// transcript makes its item unsupported without any LLM call.
enum ActionItemVerifier {
    /// Seconds of transcript on each side of a claim's timestamp shown to the verifier.
    static let windowRadius: Double = 60
    static let quoteNotFoundReason = "The quoted words do not occur in the transcript."

    enum ClaimKind: String {
        case actionItem = "action item"
        case decision
    }

    /// An item whose quote was found, to be checked by the verifier call.
    struct Claim: Equatable {
        /// `a<n>` / `d<n>`: the item's 1-based position in `actionItems` / `decisions`.
        let id: String
        let kind: ClaimKind
        let text: String
        let owner: String?
        let due: String?
        let quote: String
        /// Time of the line where the quote was found.
        let seconds: Double
    }

    /// The deterministic half of verification. Items without a quote stay
    /// as they are (`.unverified`, never auto-accepted). Items whose quote is
    /// not found (score below ``FuzzyText/matchThreshold``) become
    /// `.unsupported` with ``quoteNotFoundReason``. A found quote shorter than
    /// ``FuzzyText/minimumFuzzyLength`` normalised characters is no evidence on
    /// its own: the item stays as it is, without a claim. Other found items
    /// are reset to `.unverified` (no stale verdict survives a re-run), get the
    /// located line's label as timestamp (fixing a mis-cited `[mm:ss]`; kept
    /// when the line is the synthetic start of an untimed transcript) and a
    /// ``Claim``. Claim ids follow list position, so `a3` is always the third
    /// action item even when earlier ones produced no claim.
    static func precheck(_ facts: SummaryFacts, index: TranscriptIndex) -> (facts: SummaryFacts, claims: [Claim]) {
        var result = facts
        var claims: [Claim] = []

        for (i, item) in facts.actionItems.enumerated() {
            switch check(item.quote, timestamp: item.timestamp, in: index) {
            case .noEvidence:
                continue
            case .notFound:
                result.actionItems[i].verified = .unsupported
                result.actionItems[i].verificationReason = quoteNotFoundReason
            case let .found(line, quote):
                result.actionItems[i].verified = .unverified
                result.actionItems[i].verificationReason = nil
                if !index.isSynthetic(line) { result.actionItems[i].timestamp = line.label }
                claims.append(Claim(id: "a\(i + 1)", kind: .actionItem, text: item.task, owner: item.owner,
                                    due: item.due, quote: quote, seconds: line.seconds))
            }
        }

        for (i, decision) in facts.decisions.enumerated() {
            switch check(decision.quote, timestamp: decision.timestamp, in: index) {
            case .noEvidence:
                continue
            case .notFound:
                result.decisions[i].verified = .unsupported
                result.decisions[i].verificationReason = quoteNotFoundReason
            case let .found(line, quote):
                result.decisions[i].verified = .unverified
                result.decisions[i].verificationReason = nil
                if !index.isSynthetic(line) { result.decisions[i].timestamp = line.label }
                claims.append(Claim(id: "d\(i + 1)", kind: .decision, text: decision.text, owner: nil,
                                    due: nil, quote: quote, seconds: line.seconds))
            }
        }
        return (result, claims)
    }

    /// Seconds for an item's cited timestamp (`mm:ss` or `h:mm:ss`, optionally
    /// in brackets), or nil when it is missing or out of range: every
    /// component after the first, and `mm` of a `mm:ss` label, must be < 60
    /// (``TranscriptLineFormat/seconds(fromLabel:)`` alone accepts `99:99`).
    static func itemSeconds(_ timestamp: String?) -> Double? {
        guard var label = timestamp?.trimmingCharacters(in: .whitespaces) else { return nil }
        if label.hasPrefix("["), label.hasSuffix("]"), label.count >= 2 {
            label = String(label.dropFirst().dropLast())
        }
        guard let seconds = TranscriptLineFormat.seconds(fromLabel: label) else { return nil }
        let parts = label.split(separator: ":").compactMap { Int($0) }
        let bounded = parts.count == 2 ? parts : Array(parts.dropFirst())
        guard bounded.allSatisfy({ $0 < 60 }) else { return nil }
        return seconds
    }

    private enum QuoteCheck {
        /// No quote, or one too short to count as evidence when found.
        case noEvidence
        case notFound
        case found(TranscriptLine, quote: String)
    }

    private static func check(_ quote: String?, timestamp: String?, in index: TranscriptIndex) -> QuoteCheck {
        guard let quote else { return .noEvidence }
        let normalizedLength = FuzzyText.normalized(quote).count
        guard normalizedLength > 0 else { return .noEvidence }
        let match = index.locate(quote: quote, near: itemSeconds(timestamp))
        guard match.score >= FuzzyText.matchThreshold, let line = match.line else { return .notFound }
        guard normalizedLength >= FuzzyText.minimumFuzzyLength else { return .noEvidence }
        return .found(line, quote: quote)
    }
}

// MARK: - Verification call

extension ActionItemVerifier {
    /// Seconds on each side of a claim when the ±``windowRadius`` excerpts do not fit the budget.
    static let narrowWindowRadius: Double = 30

    /// The one verification prompt: every claim with its transcript excerpt
    /// (original line text, speaker prefixes included). Fits `budgetTokens`
    /// (``LLMPromptSupport/budgetTokens(_:)``): excerpts span ±``windowRadius``
    /// s, else ±``narrowWindowRadius`` s, else the narrow excerpts are each
    /// middle-elided to an equal share of the room left. Should even the
    /// claims without excerpts not fit, trailing claims are left out (their
    /// items stay `.unverified`). Ids are shown as they are (`a1`, `a3`, `d2`):
    /// they follow list positions, so they can have gaps.
    static func prompt(claims: [Claim], index: TranscriptIndex, meetingDate: Date, calendar: Calendar,
                       budgetTokens: Int) -> String {
        let date = isoDate(meetingDate, calendar)
        func fits(_ text: String) -> Bool { LLMPromptSupport.budgetTokens(text) <= budgetTokens }

        for radius in [windowRadius, narrowWindowRadius] {
            let text = render(claims, excerpts: claims.map { excerpt(for: $0, index: index, radius: radius) }, date: date)
            if fits(text) { return text }
        }

        // Equal shares of the characters left after everything but the excerpts.
        let maxChars = max(0, budgetTokens) * LLMPromptSupport.budgetCharsPerToken
        let narrow = claims.map { excerpt(for: $0, index: index, radius: narrowWindowRadius) }
        var count = claims.count
        while count > 0 {
            let kept = Array(claims.prefix(count))
            let excerpts = Array(narrow.prefix(count))
            let overhead = render(kept, excerpts: excerpts.map { ($0.header, "") }, date: date).count
            let share = (maxChars - overhead) / count
            if share >= 0 {
                let text = render(kept, excerpts: excerpts.map {
                    ($0.header, LLMPromptSupport.middleElide($0.lines, toCharBudget: share))
                }, date: date)
                if fits(text) { return text }
            }
            count -= 1
        }
        return render([], excerpts: [], date: date)
    }

    /// The claims' verdicts applied to `facts`: `supported: true` → `.supported`,
    /// `false` → `.unsupported`, each with its `reason`. Ids that are not a
    /// claim's, entries without a readable `supported`, and claims the reply
    /// leaves out change nothing (those items stay `.unverified`); the first
    /// entry for an id wins. Lenient: the text from the first `[` to the last
    /// `]` (fence and reasoning tags around it are fine), booleans also as
    /// `"true"`/`"false"` or 1/0. `nil` when no JSON array can be read.
    static func apply(response: String, claims: [Claim], to facts: SummaryFacts) -> SummaryFacts? {
        guard let arrayText = SummaryFactsParser.extractJSONArray(LLMPromptSupport.stripReasoningTags(response)),
              let data = arrayText.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }

        let claimIDs = Set(claims.map { $0.id.lowercased() })
        var seen = Set<String>()
        var result = facts
        for case let entry as [String: Any] in entries {
            guard let rawID = entry["id"] as? String else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard claimIDs.contains(id), let supported = boolean(entry["supported"]),
                  seen.insert(id).inserted, let position = Int(id.dropFirst()), position >= 1
            else { continue }
            let verdict: VerificationState = supported ? .supported : .unsupported
            let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kept = reason.flatMap { $0.isEmpty ? nil : $0 }
            switch id.first {
            case "a" where position <= result.actionItems.count:
                result.actionItems[position - 1].verified = verdict
                result.actionItems[position - 1].verificationReason = kept
            case "d" where position <= result.decisions.count:
                result.decisions[position - 1].verified = verdict
                result.decisions[position - 1].verificationReason = kept
            default:
                continue
            }
        }
        return result
    }

    /// The verification repair prompt for an unreadable reply.
    static func repairPrompt(broken: String) -> String {
        """
        The text below was meant to be one JSON array of objects {"id": "...", "supported": true or false, "reason": "..."}, but it is not valid JSON. Return only the corrected JSON array — no prose and no code fence. Keep every entry; do not add entries.

        Text:
        \(broken)
        """
    }

    // MARK: Private

    private static let instructions = """
    You are checking meeting notes against the transcript they were written from.
    For each claim below, decide whether the transcript excerpt supports it. A decision is supported only if the excerpt shows it was actually decided or agreed. An action item is supported only if the excerpt shows the action was taken on — by the named owner, if one is given — and the due date, if one is given, was said or clearly implied.
    Answer with only one JSON array, no prose and no code fence, with one object per claim in the same order:
    [{"id": "<claim id>", "supported": true, "reason": "<one short sentence in the language of the transcript>"}]
    When in doubt, answer false.
    """

    /// The excerpt heading (`Transcript excerpt (03:10–04:20):`) and its lines.
    private static func excerpt(for claim: Claim, index: TranscriptIndex,
                                radius: Double) -> (header: String, lines: String) {
        let window = index.window(around: claim.seconds, radius: radius)
        let first = window.first?.label ?? TranscriptLineFormat.timestampLabel(seconds: claim.seconds)
        let last = window.last?.label ?? first
        let header = "Transcript excerpt (\(first)–\(last)):"
        let lines = window.map { line in
            "[\(line.label)] " + (line.speaker.map { "\($0): " } ?? "") + line.text
        }
        return (header, lines.joined(separator: "\n"))
    }

    private static func render(_ claims: [Claim], excerpts: [(header: String, lines: String)], date: String) -> String {
        let blocks = zip(claims, excerpts).map { claim, excerpt in
            """
            ### \(claim.id) (\(claim.kind.rawValue))
            Claim: \(singleLine(claim.text))
            Owner: \(claim.owner.map(singleLine).flatMap { $0.isEmpty ? nil : $0 } ?? "none")
            Due: \(claim.due.map(singleLine).flatMap { $0.isEmpty ? nil : $0 } ?? "none")
            Quote: "\(singleLine(claim.quote))"
            \(excerpt.header)
            \(excerpt.lines)
            """
        }
        return instructions + "\n\nMeeting date: \(date)\n\nClaims:\n" + blocks.joined(separator: "\n\n")
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `yyyy-MM-dd` of `date` in `calendar`'s time zone.
    private static func isoDate(_ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            // JSON true/false and 1/0 both arrive as NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            switch number.intValue {
            case 1: return true
            case 0: return false
            default: return nil
            }
        case let text as String:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}
