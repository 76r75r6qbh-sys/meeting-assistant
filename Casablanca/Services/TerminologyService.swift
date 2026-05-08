import Foundation

struct TerminologyEntry: Equatable {
    let canonical: String
    let aliases: [String]
}

@MainActor
@Observable
final class TerminologyService {
    private struct OllamaGenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let options: Options
        struct Options: Encodable { let temperature: Double }
    }

    private struct OllamaGenerateResponse: Decodable {
        let response: String?
        let error: String?
    }

    enum TerminologyError: Error {
        case invalidEndpoint
        case requestFailed(String)
        case emptyResponse
    }

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
            let corrected = try await runOllamaPass(transcript: dictionaryReplaced, entries: entries)
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

    /// Heuristic to detect when the Ollama model has mangled the transcript
    /// (e.g. replaced content with `***` redactions, truncated drastically,
    /// or output an apology / explanation instead of a corrected transcript).
    /// Triggers when the alphanumeric character count drops by more than half,
    /// which catches the common failure modes without flagging legitimate
    /// minor edits.
    static func looksLikeMangledOutput(input: String, output: String) -> Bool {
        let inputContent = input.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        // Skip the check for very short transcripts (less than ~20 words of
        // alphanumeric content) where small differences are noise.
        guard inputContent > 100 else { return false }
        let outputContent = output.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        return outputContent * 2 < inputContent
    }

    private func runOllamaPass(transcript: String, entries: [TerminologyEntry]) async throws -> String {
        guard let url = makeGenerateURL() else {
            throw TerminologyError.invalidEndpoint
        }

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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(
            OllamaGenerateRequest(
                model: UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaModel) ?? "llama3.2",
                prompt: prompt,
                stream: false,
                options: .init(temperature: 0)
            )
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TerminologyError.requestFailed(error.localizedDescription)
        }

        if Task.isCancelled { throw CancellationError() }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TerminologyError.requestFailed("Ollama returned an invalid response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TerminologyError.requestFailed("Ollama returned status \(httpResponse.statusCode).")
        }

        let payload = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        if let err = payload.error, !err.isEmpty {
            throw TerminologyError.requestFailed(err)
        }
        let corrected = payload.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !corrected.isEmpty else {
            throw TerminologyError.emptyResponse
        }
        return corrected
    }

    private func makeGenerateURL() -> URL? {
        let endpoint = UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434"
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("/api/generate") { return URL(string: trimmed) }
        if trimmed.hasSuffix("/api") { return URL(string: "\(trimmed)/generate") }
        if trimmed.hasSuffix("/") { return URL(string: "\(trimmed)api/generate") }
        return URL(string: "\(trimmed)/api/generate")
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
        // Build (alias, canonical) pairs, sorted by alias length descending,
        // ties broken by entry order in `entries`.
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
            // escapedTemplate ensures `$`/`\` in the canonical aren't interpreted as backreferences.
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
