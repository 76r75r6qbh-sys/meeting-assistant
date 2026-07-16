import Foundation

struct TerminologyEntry: Equatable, Sendable {
    let canonical: String
    let aliases: [String]
}

@MainActor
@Observable
final class TerminologyService {
    private(set) var isCorrecting = false
    var warningMessage: String?

    func clearWarning() {
        warningMessage = nil
    }

    /// Corrects `rawTranscript` against `entries`. Never throws — on any failure,
    /// returns the dictionary-replaced text and surfaces a `warningMessage`.
    /// `entries` is captured by value: edits to the underlying preference made
    /// after this call begins do not affect this run.
    func correct(_ rawTranscript: String, entries: [TerminologyEntry]) async -> String {
        guard !entries.isEmpty else { return rawTranscript }

        isCorrecting = true
        defer { isCorrecting = false }

        // Off the main actor: with a long alias list this is a real amount of
        // regex work, and it must not block the UI while it runs.
        let dictionaryReplaced = await Task.detached(priority: .userInitiated) {
            Self.dictionaryReplace(rawTranscript, entries: entries)
        }.value

        if Task.isCancelled { return dictionaryReplaced }

        do {
            let corrected = try await runProviderPass(transcript: dictionaryReplaced, entries: entries)
            if Self.looksLikeMangledOutput(input: dictionaryReplaced, output: corrected) {
                warningMessage = "Terminology correction produced unexpected output and was discarded; transcript reflects only deterministic replacements."
                return dictionaryReplaced
            }
            return corrected
        } catch {
            warningMessage = "Terminology correction is unavailable; transcript reflects only deterministic replacements."
            return dictionaryReplaced
        }
    }

    /// Heuristic to detect when the model has mangled the transcript
    /// (e.g. replaced content with `***` redactions, truncated drastically,
    /// or output an apology / explanation instead of a corrected transcript).
    /// Triggers when the alphanumeric character count drops by more than half,
    /// which catches the common failure modes without flagging legitimate
    /// minor edits.
    nonisolated static func looksLikeMangledOutput(input: String, output: String) -> Bool {
        let inputContent = input.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard inputContent > 100 else { return false }
        let outputContent = output.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        return outputContent * 2 < inputContent
    }

    // NOTE: unlike SummarizationService/MeetingChatService, the transcript here
    // is deliberately NOT bounded with `LLMPromptSupport.truncated` — this
    // pass's output IS the transcript that gets saved. Truncating the input
    // would truncate the model's echoed output, silently deleting the elided
    // middle of the meeting. So instead of shrinking the input, the timeout is
    // scaled to it: this app's own transcripts run up to ~80k characters, and a
    // fixed 60s timeout was silently failing on the largest ones (falling back
    // to the regex-only result with no visible error).
    //
    // Rough heuristic, not a measured benchmark — assumes ~40 chars/sec of
    // combined prompt-processing + full-length generation throughput on a local
    // model, clamped to a sane range. Tune `charsPerSecondEstimate` if real-world
    // timing looks off.
    nonisolated private static let charsPerSecondEstimate: Double = 40
    nonisolated private static let minTimeout: TimeInterval = 60
    nonisolated private static let maxTimeout: TimeInterval = 240

    nonisolated static func estimatedTimeout(forTranscriptLength length: Int) -> TimeInterval {
        let estimated = Double(length) / charsPerSecondEstimate
        return min(max(estimated, minTimeout), maxTimeout)
    }

    private func runProviderPass(transcript: String, entries: [TerminologyEntry]) async throws -> String {
        let prompt = """
        You are correcting domain-specific terminology in a meeting transcript.

        The following terms must appear with their exact spelling:
        \(Self.formattedForPrompt(entries))

        Rules:
        - Fix only misspellings or phonetic mistranscriptions of the terms above.
        - Do not rephrase, translate, summarize, add, or remove anything else.
        - Preserve all timestamps, speaker labels, line breaks, and punctuation exactly.
        - Output only the corrected transcript. No preamble, no commentary.

        Transcript:
        \(transcript)
        """

        return try await LLMProviderFactory.current().generate(
            prompt: prompt,
            temperature: 0,
            maxTokens: nil,
            timeout: Self.estimatedTimeout(forTranscriptLength: transcript.count),
            truncated: nil
        )
    }

    // `parse` is called on every transcription AND on every summarize() call
    // (via `renderTerminologyBlock`), always with the same raw preference
    // string in between edits — so a size-1 cache keyed on that string turns
    // most calls into a lock + string comparison instead of a full re-parse.
    nonisolated(unsafe) private static let parseCacheLock = NSLock()
    nonisolated(unsafe) private static var parseCacheRaw: String?
    nonisolated(unsafe) private static var parseCacheEntries: [TerminologyEntry] = []

    nonisolated static func parse(_ raw: String) -> [TerminologyEntry] {
        parseCacheLock.lock()
        defer { parseCacheLock.unlock() }
        if let parseCacheRaw, parseCacheRaw == raw {
            return parseCacheEntries
        }
        let entries = parseUncached(raw)
        parseCacheRaw = raw
        parseCacheEntries = entries
        return entries
    }

    nonisolated private static func parseUncached(_ raw: String) -> [TerminologyEntry] {
        var entries: [TerminologyEntry] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let canonical = parts[0].trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }

            var aliases: [String] = []
            if parts.count == 2 {
                aliases = parts[1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            entries.append(TerminologyEntry(canonical: canonical, aliases: aliases))
        }
        return entries
    }

    /// A single compiled alternation over every alias, plus a lowercase
    /// alias → canonical lookup. Aliases are ordered longest-first so that
    /// when one alias is a substring of another (e.g. "AI" vs. "AI infra"),
    /// the more specific one wins at a given position.
    private struct CompiledDictionary {
        let regex: NSRegularExpression
        let lookup: [String: String]
    }

    nonisolated(unsafe) private static let compileCacheLock = NSLock()
    nonisolated(unsafe) private static var compileCacheEntries: [TerminologyEntry]?
    nonisolated(unsafe) private static var compileCacheResult: CompiledDictionary?

    nonisolated private static func compiledDictionary(for entries: [TerminologyEntry]) -> CompiledDictionary? {
        compileCacheLock.lock()
        defer { compileCacheLock.unlock() }
        if let compileCacheEntries, compileCacheEntries == entries {
            return compileCacheResult
        }

        var ordered: [(alias: String, canonical: String, order: Int)] = []
        for (index, entry) in entries.enumerated() {
            for alias in entry.aliases {
                ordered.append((alias: alias, canonical: entry.canonical, order: index))
            }
        }
        ordered.sort { lhs, rhs in
            if lhs.alias.count != rhs.alias.count {
                return lhs.alias.count > rhs.alias.count
            }
            return lhs.order < rhs.order
        }

        var built: CompiledDictionary?
        if !ordered.isEmpty {
            var lookup: [String: String] = [:]
            let patterns = ordered.map { pair -> String in
                lookup[pair.alias.lowercased()] = pair.canonical
                return NSRegularExpression.escapedPattern(for: pair.alias)
            }
            let pattern = "\\b(?:\(patterns.joined(separator: "|")))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                built = CompiledDictionary(regex: regex, lookup: lookup)
            }
        }

        compileCacheEntries = entries
        compileCacheResult = built
        return built
    }

    /// Single scan over `text` regardless of alias-list size, instead of one
    /// full-text regex pass per alias.
    nonisolated static func dictionaryReplace(_ text: String, entries: [TerminologyEntry]) -> String {
        guard let compiled = compiledDictionary(for: entries) else { return text }

        let nsText = text as NSString
        let matches = compiled.regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(nsText.length)
        var lastEnd = 0
        for match in matches {
            let range = match.range
            guard range.location >= lastEnd else { continue }
            result += nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            let matchedText = nsText.substring(with: range)
            result += compiled.lookup[matchedText.lowercased()] ?? matchedText
            lastEnd = range.location + range.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    nonisolated static func formattedForPrompt(_ entries: [TerminologyEntry]) -> String {
        entries.map { "- \($0.canonical)" }.joined(separator: "\n")
    }

    nonisolated static func renderTerminologyBlock(enabled: Bool, raw: String) -> String {
        guard enabled else { return "" }
        let entries = parse(raw)
        guard !entries.isEmpty else { return "" }
        return """
        Domain terminology to preserve (use these exact spellings):
        \(formattedForPrompt(entries))
        """
    }
}
