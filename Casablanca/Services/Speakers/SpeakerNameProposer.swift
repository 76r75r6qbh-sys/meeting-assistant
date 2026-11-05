import Foundation

/// Speaker preference keys owned by Track A. `AppPreferenceKey` lives in the
/// reserved `Meeting.swift`; Phase 2 moves this key there.
enum SpeakerPreferenceKey {
    /// Ask the LLM for speaker names after each transcription. Default off:
    /// no automatic LLM call without the user's opt-in. "Suggest names" in the
    /// speakers bar works either way.
    static let suggestSpeakerNamesAutomatically = "suggestSpeakerNamesAutomatically"
}

/// Asks the LLM who the anonymous speakers are, from the participant list and
/// the first minutes of the transcript.
///
/// The answers are suggestions only: the speakers bar shows each with its
/// evidence quote and applies it when the user taps it. `parse` keeps an answer
/// only when the transcript backs it up, so a guess from the participant list
/// alone never reaches the user. One call, no retry: a failure means no
/// suggestions, never a failed transcription.
struct SpeakerNameProposer {
    /// Only lines before this many seconds go into the prompt; introductions
    /// happen at the start.
    static let transcriptWindowSeconds = 600.0
    /// Cap on the transcript part of the prompt (~4k tokens, within a local
    /// model's budget).
    static let maxPromptCharacters = 12_000
    /// Room for one short entry per speaker.
    static let maxOutputTokens = 800

    private let providerFactory: () -> LLMProvider

    init(providerFactory: @escaping () -> LLMProvider = { LLMProviderFactory.current() }) {
        self.providerFactory = providerFactory
    }

    // MARK: - Propose

    /// Suggestions for `meeting`'s unnamed speakers. Reads the meeting, never
    /// writes it.
    @MainActor
    func propose(for meeting: Meeting) async -> [SpeakerNameSuggestion] {
        await propose(
            speakers: meeting.speakers,
            participants: meeting.participants,
            transcript: meeting.transcript ?? ""
        )
    }

    /// Suggestions for the unnamed speakers in `transcript`. `[]` without
    /// candidates (no LLM call), on any provider error, or for an answer that
    /// does not parse.
    @MainActor
    func propose(speakers: [SpeakerInfo], participants: [String], transcript: String) async -> [SpeakerNameSuggestion] {
        guard !Self.candidates(speakers).isEmpty else { return [] }
        let prompt = Self.prompt(speakers: speakers, participants: participants, transcript: transcript)
        let provider = providerFactory()
        do {
            let response = try await provider.generate(
                prompt: LLMPromptSupport.applyThinkingSwitch(to: prompt, thinkingEnabled: false),
                temperature: 0,
                maxTokens: Self.maxOutputTokens,
                timeout: provider.timeout(orDefault: 120),
                truncated: nil
            )
            let suggestions = Self.parse(response, speakers: speakers, participants: participants, transcript: transcript)
            Log.transcription.notice("speaker name suggestions: \(suggestions.count, privacy: .public)")
            return suggestions
        } catch {
            Log.transcription.error(
                "Speaker name suggestions failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// The speakers worth naming: not the user, not confirmed, and not the
    /// undiarized far end (`Others` is several people).
    static func candidates(_ speakers: [SpeakerInfo]) -> [SpeakerInfo] {
        speakers.filter { !$0.isUser && !$0.nameConfirmed && $0.id != SpeakerIDs.others }
    }

    // MARK: - Prompt

    static func prompt(speakers: [SpeakerInfo], participants: [String], transcript: String) -> String {
        let speakerLines = candidates(speakers)
            .map { "\($0.id): \(TranscriptLineFormat.sanitizedSpeakerName($0.displayName))" }
            .joined(separator: "\n")
        let participantLines = participants.isEmpty
            ? "- (none listed)"
            : participants.map { "- \($0)" }.joined(separator: "\n")

        return """
        Speaker recognition split the voices in this meeting into anonymous labels. Work out who each label is, \
        using only what the transcript itself says: a speaker introducing themselves, being addressed by name just \
        before they answer, or being named by someone else. Never guess from the participant list alone.

        Speakers to name (id: label):
        \(speakerLines)

        Participants from the calendar invite:
        \(participantLines)

        Transcript (first \(Int(transcriptWindowSeconds / 60)) minutes):
        \(windowedTranscript(transcript))

        Answer with JSON only, no other text:
        [{"speakerID": "...", "name": "...|null", "evidence": "verbatim quote"}]
        One entry per speaker id above. Use null for the name when the transcript does not make it clear. \
        The evidence is a short quote copied word for word from the transcript that shows the name.
        """
    }

    /// The timestamped lines before ``transcriptWindowSeconds``, cut at
    /// ``maxPromptCharacters``.
    static func windowedTranscript(_ transcript: String) -> String {
        var kept: [String] = []
        var characters = 0
        for rawLine in transcript.components(separatedBy: .newlines) {
            guard let line = TranscriptLineFormat.parse(rawLine), line.seconds < transcriptWindowSeconds else { continue }
            guard characters + rawLine.count + 1 <= maxPromptCharacters else { break }
            kept.append(rawLine)
            characters += rawLine.count + 1
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Parse

    private struct Entry: Decodable {
        var speakerID: String
        var name: String?
        var evidence: String?
    }

    /// The answers the transcript backs up. An entry is kept only when its
    /// speaker is a candidate, its name is a participant (or a participant's
    /// first name) or occurs in the spoken text, and its evidence occurs in the
    /// spoken text (case and whitespace ignored). One per speaker, the first.
    /// Anything that does not parse gives `[]`.
    static func parse(
        _ response: String,
        speakers: [SpeakerInfo],
        participants: [String],
        transcript: String
    ) -> [SpeakerNameSuggestion] {
        let cleaned = LLMPromptSupport.stripReasoningTags(response)
        guard let open = cleaned.firstIndex(of: "["),
              let close = cleaned.lastIndex(of: "]"),
              open < close,
              let data = String(cleaned[open...close]).data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }

        let candidateIDs = Set(candidates(speakers).map(\.id))
        // Labels such as "Speaker 1" are not names, wherever they occur.
        let labels = Set(speakers.filter { !$0.nameConfirmed }.map { normalize($0.displayName) })
        let spoken = normalize(spokenText(transcript, speakers: speakers))

        var seen: Set<String> = []
        var suggestions: [SpeakerNameSuggestion] = []
        for entry in entries {
            guard candidateIDs.contains(entry.speakerID), !seen.contains(entry.speakerID),
                  let rawName = entry.name,
                  let name = resolvedName(rawName, participants: participants, spoken: spoken),
                  !labels.contains(normalize(name))
            else { continue }
            let evidence = (entry.evidence ?? "").trimmingCharacters(in: quoteAndSpace)
            let normalizedEvidence = normalize(evidence)
            guard !normalizedEvidence.isEmpty, spoken.contains(normalizedEvidence) else { continue }

            seen.insert(entry.speakerID)
            suggestions.append(SpeakerNameSuggestion(
                speakerID: entry.speakerID,
                name: name,
                evidence: evidence,
                source: .transcript,
                score: nil
            ))
        }
        return suggestions
    }

    /// The name to offer: a participant's full name when `raw` is that name or
    /// the first name of exactly one participant; `raw` itself when it is
    /// another participant's first name or occurs as a word in `spoken`;
    /// otherwise `nil`.
    private static func resolvedName(_ raw: String, participants: [String], spoken: String) -> String? {
        let name = TranscriptLineFormat.sanitizedSpeakerName(raw)
        guard !name.isEmpty else { return nil }
        let key = normalize(name)

        if let participant = participants.first(where: { normalize($0) == key }) {
            let full = TranscriptLineFormat.sanitizedSpeakerName(participant)
            return full.isEmpty ? name : full
        }
        let firstNameMatches = participants.filter { participant in
            normalize(participant).split(separator: " ").first.map(String.init) == key
        }
        if firstNameMatches.count == 1 {
            let full = TranscriptLineFormat.sanitizedSpeakerName(firstNameMatches[0])
            return full.isEmpty ? name : full
        }
        if !firstNameMatches.isEmpty || occursAsWords(key, in: spoken) { return name }
        return nil
    }

    /// The transcript without its speaker prefixes, so a label such as
    /// `Speaker 1:` never counts as something said.
    private static func spokenText(_ transcript: String, speakers: [SpeakerInfo]) -> String {
        let known = Set(speakers.map { TranscriptLineFormat.sanitizedSpeakerName($0.displayName) }.filter { !$0.isEmpty })
        return transcript.components(separatedBy: .newlines).map { line in
            TranscriptLineFormat.parse(line, knownSpeakers: known)?.text ?? line
        }.joined(separator: "\n")
    }

    private static func occursAsWords(_ phrase: String, in text: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Lowercased, whitespace runs collapsed to one space, trimmed.
    private static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let quoteAndSpace = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
}
