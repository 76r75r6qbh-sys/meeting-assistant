import Foundation

/// Turns the user's terminology list into Whisper prompt tokens, and recognises
/// the prompt when Whisper echoes it back.
///
/// Whisper conditions each window on "previous text" tokens (`<|startofprev|>`
/// … ). Feeding it the canonical spellings ("Wegiz, BgZ, Medicore") biases the
/// decoder towards them at the source, before the dictionary pass ever runs.
/// The cost is Whisper's well-known prompt hallucination: on a window with no
/// speech it may emit the prompt itself as the transcript. `isPromptEcho`
/// catches those segments so they can be dropped.
enum WhisperPromptBuilder {
    /// Whisper's text context is 448 tokens and WhisperKit keeps at most
    /// `n_text_ctx / 2 − 1` of a prompt (`TextDecoder.prepareDecoderInputs`),
    /// which also satisfies the spec's ≤ 224.
    static let maxPromptTokens = 223

    /// Canonical forms in list order, deduplicated case-insensitively (the
    /// first spelling wins). Empty when terminology correction is off.
    static func terms(enabled: Bool, raw: String) -> [String] {
        guard enabled else { return [] }
        var seen = Set<String>()
        var terms: [String] = []
        for entry in TerminologyService.parse(raw) where seen.insert(entry.canonical.lowercased()).inserted {
            terms.append(entry.canonical)
        }
        return terms
    }

    /// The prompt text for the first terms: a leading space (Whisper's word
    /// tokens carry their own leading space) and a comma-separated list.
    static func promptText(for terms: [String]) -> String {
        " " + terms.joined(separator: ", ")
    }

    /// Encodes the longest whole-term prefix of `terms` whose token count,
    /// after dropping special tokens (`>= specialTokenBegin`, which WhisperKit
    /// filters out of a prompt anyway), is at most `limit`. A term is never
    /// cut in half: a partial "Medi" would bias the decoder towards a word
    /// that does not exist. An empty result means no prompt.
    ///
    /// Grows `k` one term at a time and stops at the first prefix that no
    /// longer fits — appending ", term" never shortens a BPE encoding in
    /// practice, so that is the largest `k`, and it costs at most one encode
    /// past the limit rather than one per term on a 300-term list.
    static func tokens(
        for terms: [String],
        encode: (String) -> [Int],
        specialTokenBegin: Int,
        limit: Int = maxPromptTokens
    ) -> [Int] {
        prompt(for: terms, encode: encode, specialTokenBegin: specialTokenBegin, limit: limit).tokens
    }

    /// The prompt actually sent: the whole terms that fit and their tokens.
    /// `terms` is what the echo filter must compare against — a term that did
    /// not fit was never in the prompt, so Whisper cannot echo it.
    struct Prompt: Equatable {
        let terms: [String]
        let tokens: [Int]
    }

    /// See `tokens(for:encode:specialTokenBegin:limit:)`; also returns the
    /// terms the tokens encode. Both are empty when nothing fits.
    static func prompt(
        for terms: [String],
        encode: (String) -> [Int],
        specialTokenBegin: Int,
        limit: Int = maxPromptTokens
    ) -> Prompt {
        guard limit > 0 else { return Prompt(terms: [], tokens: []) }
        var best = Prompt(terms: [], tokens: [])
        for k in terms.indices.map({ $0 + 1 }) {
            let prefix = Array(terms.prefix(k))
            let candidate = encode(promptText(for: prefix)).filter { $0 < specialTokenBegin }
            guard candidate.count <= limit else { break }
            best = Prompt(terms: prefix, tokens: candidate)
        }
        return best
    }

    /// Minimum length (normalised characters) for a partial echo to count.
    /// Shorter prefixes ("Wegiz, BgZ") are things people actually say.
    static let minimumEchoPrefixLength = 20

    /// A segment that is mostly a list of prompt terms, in any order, is an
    /// echo too: at least `minimumEchoTermCount` term matches covering at
    /// least `minimumEchoTermCoverage` of the segment's words. A real sentence
    /// mentions one or two terms among ordinary words and stays well below.
    static let minimumEchoTermCount = 3
    static let minimumEchoTermCoverage = 0.8

    /// True when `segmentText` is the prompt played back:
    /// - its normalised form (lowercase, letters and digits only) equals the
    ///   normalised joined prompt, or is a prefix of it at least
    ///   `minimumEchoPrefixLength` long; or
    /// - it is a run of prompt terms in any order (a shuffled list, a suffix
    ///   of the prompt): see `minimumEchoTermCount`/`minimumEchoTermCoverage`.
    ///
    /// `terms` must be the terms actually sent (`Prompt.terms`).
    static func isPromptEcho(_ segmentText: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let segment = normalised(segmentText)
        guard !segment.isEmpty else { return false }
        let prompt = normalised(terms.joined(separator: ", "))
        if segment == prompt { return true }
        if segment.count >= minimumEchoPrefixLength && prompt.hasPrefix(segment) { return true }
        return isTermRun(segmentText, terms: terms)
    }

    private static func isTermRun(_ segmentText: String, terms: [String]) -> Bool {
        let words = self.words(segmentText)
        guard !words.isEmpty else { return false }
        // Longest terms first, so "Medicore EPD" wins over "Medicore".
        let termWords = Set(terms.map(self.words).filter { !$0.isEmpty })
            .sorted { $0.count > $1.count }
        var index = 0
        var matches = 0
        var covered = 0
        while index < words.count {
            if let match = termWords.first(where: { term in
                index + term.count <= words.count && Array(words[index ..< index + term.count]) == term
            }) {
                matches += 1
                covered += match.count
                index += match.count
            } else {
                index += 1
            }
        }
        return matches >= minimumEchoTermCount
            && Double(covered) / Double(words.count) >= minimumEchoTermCoverage
    }

    private static func normalised(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Lowercased runs of letters and digits; punctuation and spaces split.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }
}
