// Casablanca/Services/TranscriptChunker.swift
import Foundation

/// One part of a transcript too long for a single prompt. Map-reduce
/// summarization condenses each part separately, so the labels give the map
/// prompt a "(start–end)" header the model can anchor its timestamps to.
struct TranscriptChunk: Equatable {
    let index: Int            // 0-based
    let text: String
    let startLabel: String?   // first "[mm:ss]" / "[h:mm:ss]" label in the chunk, without brackets
    let endLabel: String?     // last such label
}

/// Splits a transcript into prompt-sized parts on line boundaries. Casablanca
/// transcripts are `[mm:ss] text` lines, so a line is the natural unit: cutting
/// inside one would separate a statement from its timestamp. Pure and
/// deterministic, so a retry re-produces identical parts (the summary cache is
/// keyed per part index).
enum TranscriptChunker {
    /// - Parameters:
    ///   - chunkTokens: upper bound, in `LLMPromptSupport.budgetTokens`, for each
    ///     part's full text including its overlap prefix.
    ///   - overlapTokens: each part after the first starts with the trailing whole
    ///     lines of the previous part totalling at most this, so a statement
    ///     split across a boundary keeps its context. Overlap is shrunk (to zero
    ///     if need be) whenever it would leave no room for a new line — which is
    ///     also what guarantees progress when `overlapTokens >= chunkTokens`.
    static func chunks(of transcript: String, chunkTokens: Int, overlapTokens: Int) -> [TranscriptChunk] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let chunkTokens = max(1, chunkTokens)
        let overlapTokens = max(0, overlapTokens)

        let lines = trimmed
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        if LLMPromptSupport.budgetTokens(trimmed) <= chunkTokens {
            return [makeChunk(index: 0, lines: lines, text: trimmed)]
        }

        let units = lines.flatMap { hardSplit($0, chunkTokens: chunkTokens) }

        var result: [TranscriptChunk] = []
        var overlap: [String] = []
        var next = 0
        while next < units.count {
            // Make room for at least one new unit by dropping overlap from the
            // front; every unit fits on its own, so this always terminates.
            var current = overlap
            var chars = joinedCount(current)
            while !current.isEmpty, tokens(chars, adding: units[next], to: current.count) > chunkTokens {
                chars -= current[0].count + (current.count > 1 ? 1 : 0)
                current.removeFirst()
            }
            chars = appended(chars, units[next], to: current.count)
            current.append(units[next])
            next += 1

            while next < units.count, tokens(chars, adding: units[next], to: current.count) <= chunkTokens {
                chars = appended(chars, units[next], to: current.count)
                current.append(units[next])
                next += 1
            }

            result.append(makeChunk(index: result.count, lines: current, text: current.joined(separator: "\n")))
            overlap = trailingLines(of: current, maxTokens: overlapTokens)
        }
        return result
    }

    // MARK: - Size bookkeeping

    /// Character count of `lines.joined(separator: "\n")`, without joining.
    private static func joinedCount(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.count } + max(0, lines.count - 1)
    }

    private static func appended(_ chars: Int, _ line: String, to lineCount: Int) -> Int {
        chars + line.count + (lineCount > 0 ? 1 : 0)
    }

    private static func tokens(_ chars: Int, adding line: String, to lineCount: Int) -> Int {
        LLMPromptSupport.budgetTokens(forCharCount: appended(chars, line, to: lineCount))
    }

    /// The longest run of whole trailing lines whose joined text is within
    /// `maxTokens`; empty when the last line alone exceeds it.
    private static func trailingLines(of lines: [String], maxTokens: Int) -> [String] {
        var taken: [String] = []
        var chars = 0
        for line in lines.reversed() {
            let candidate = appended(chars, line, to: taken.count)
            guard LLMPromptSupport.budgetTokens(forCharCount: candidate) <= maxTokens else { break }
            chars = candidate
            taken.append(line)
        }
        return taken.reversed()
    }

    // MARK: - Oversized lines

    /// Splits a line over `chunkTokens` into pieces that each fit, cutting at
    /// the last whitespace before the limit (the whitespace itself is dropped)
    /// or exactly at the limit when the stretch has none. A transcription
    /// segment can run for minutes without a newline, and one part must never
    /// exceed the budget.
    private static func hardSplit(_ line: String, chunkTokens: Int) -> [String] {
        let limit = chunkTokens * LLMPromptSupport.budgetCharsPerToken
        var pieces: [String] = []
        var rest = Substring(line)
        while LLMPromptSupport.budgetTokens(forCharCount: rest.count) > chunkTokens {
            let window = rest.prefix(limit)
            if let space = window.lastIndex(where: \.isWhitespace), space > window.startIndex {
                pieces.append(String(rest[..<space]))
                rest = rest[rest.index(after: space)...]
            } else {
                pieces.append(String(window))
                rest = rest[window.endIndex...]
            }
        }
        pieces.append(String(rest))
        return pieces
    }

    // MARK: - Timestamp labels

    private static func makeChunk(index: Int, lines: [String], text: String) -> TranscriptChunk {
        let labels = lines.compactMap(label(of:))
        return TranscriptChunk(index: index, text: text, startLabel: labels.first, endLabel: labels.last)
    }

    /// The text inside a leading `[mm:ss]` / `[h:mm:ss]` label — the regex
    /// `^\[(\d{1,2}:)?\d{1,2}:\d{2}\]` — or nil. Hand-parsed rather than a
    /// stored regex so the type stays free of non-Sendable statics.
    static func label(of line: String) -> String? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close]
        let fields = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let isASCIIDigits: (Substring) -> Bool = { $0.allSatisfy { $0.isASCII && $0.isNumber } }
        guard fields.allSatisfy(isASCIIDigits),
              fields.last!.count == 2,
              fields.dropLast().allSatisfy({ (1...2).contains($0.count) })
        else { return nil }
        return String(inner)
    }
}
