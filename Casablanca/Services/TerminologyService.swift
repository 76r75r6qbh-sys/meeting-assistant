import Foundation

struct TerminologyEntry: Equatable {
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

        let dictionaryReplaced = Self.dictionaryReplace(rawTranscript, entries: entries)

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
    static func looksLikeMangledOutput(input: String, output: String) -> Bool {
        let inputContent = input.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard inputContent > 100 else { return false }
        let outputContent = output.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        return outputContent * 2 < inputContent
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
            timeout: 60,
            truncated: nil
        )
    }

    static func parse(_ raw: String) -> [TerminologyEntry] {
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

    static func dictionaryReplace(_ text: String, entries: [TerminologyEntry]) -> String {
        var pairs: [(alias: String, canonical: String, order: Int)] = []
        for (index, entry) in entries.enumerated() {
            for alias in entry.aliases {
                pairs.append((alias: alias, canonical: entry.canonical, order: index))
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.alias.count != rhs.alias.count {
                return lhs.alias.count > rhs.alias.count
            }
            return lhs.order < rhs.order
        }

        var result = text
        for pair in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: pair.alias)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: pair.canonical)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    static func formattedForPrompt(_ entries: [TerminologyEntry]) -> String {
        entries.map { "- \($0.canonical)" }.joined(separator: "\n")
    }

    static func renderTerminologyBlock(enabled: Bool, raw: String) -> String {
        guard enabled else { return "" }
        let entries = parse(raw)
        guard !entries.isEmpty else { return "" }
        return """
        Domain terminology to preserve (use these exact spellings):
        \(formattedForPrompt(entries))
        """
    }
}
