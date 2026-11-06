import Foundation
import XCTest
@testable import Casablanca

/// Covers the single-pass `dictionaryReplace` rewrite: correctness parity with
/// the old per-alias-regex-pass behavior (case-insensitivity, longest-alias
/// preference, multiple distinct terms in one transcript), plus the `parse`
/// cache actually invalidating when the raw preference string changes.
final class TerminologyServiceTests: XCTestCase {

    func testReplacesSingleAliasCaseInsensitively() {
        let entries = [TerminologyEntry(canonical: "Medicore", aliases: ["Medi Core", "Medicare"])]
        let result = TerminologyService.dictionaryReplace(
            "We use medi core for everything, unlike MEDICARE.",
            entries: entries
        )
        XCTAssertEqual(result, "We use Medicore for everything, unlike Medicore.")
    }

    func testLongestAliasWinsAtOverlappingPosition() {
        // "AI infra" and "AI" both start at the same position in the text;
        // the longer, more specific alias must be preferred.
        let entries = [
            TerminologyEntry(canonical: "AI-infrastructuur", aliases: ["AI infra"]),
            TerminologyEntry(canonical: "kunstmatige intelligentie", aliases: ["AI"]),
        ]
        let result = TerminologyService.dictionaryReplace("We bespreken AI infra vandaag.", entries: entries)
        XCTAssertEqual(result, "We bespreken AI-infrastructuur vandaag.")
    }

    func testMultipleDistinctTermsInOnePass() {
        let entries = [
            TerminologyEntry(canonical: "Medicore", aliases: ["MediCorps", "MediCor"]),
            TerminologyEntry(canonical: "Orchestra", aliases: ["Orkestra", "Orcus"]),
            TerminologyEntry(canonical: "Keycloak", aliases: ["Kiekloek"]),
        ]
        let transcript = "Bij MediCorps gebruiken we Orkestra en Kiekloek voor SSO, en later nog MediCor en Orcus."
        let expected = "Bij Medicore gebruiken we Orchestra en Keycloak voor SSO, en later nog Medicore en Orchestra."
        XCTAssertEqual(TerminologyService.dictionaryReplace(transcript, entries: entries), expected)
    }

    func testNoAliasesLeavesTextUnchanged() {
        let entries = [TerminologyEntry(canonical: "Medicore", aliases: [])]
        let text = "Niets om te vervangen hier."
        XCTAssertEqual(TerminologyService.dictionaryReplace(text, entries: entries), text)
    }

    func testEmptyEntriesLeavesTextUnchanged() {
        let text = "Volledig ongemoeid transcript."
        XCTAssertEqual(TerminologyService.dictionaryReplace(text, entries: []), text)
    }

    func testWordBoundaryDoesNotMatchInsideOtherWords() {
        let entries = [TerminologyEntry(canonical: "AI", aliases: ["EI"])]
        // "EI" must not match inside "REIN" or "EIGEN".
        let text = "Rein en eigen zijn geen EI."
        XCTAssertEqual(TerminologyService.dictionaryReplace(text, entries: entries), "Rein en eigen zijn geen AI.")
    }

    func testParseCacheReturnsFreshResultAfterRawStringChanges() {
        let first = TerminologyService.parse("Medicore: Medi Core")
        XCTAssertEqual(first, [TerminologyEntry(canonical: "Medicore", aliases: ["Medi Core"])])

        let second = TerminologyService.parse("Orchestra: Orkestra")
        XCTAssertEqual(second, [TerminologyEntry(canonical: "Orchestra", aliases: ["Orkestra"])])

        // Re-requesting the first raw string must reparse correctly, not
        // return whatever the cache happened to hold last.
        let third = TerminologyService.parse("Medicore: Medi Core")
        XCTAssertEqual(third, first)
    }

    // MARK: - The provider pass, and skipping it

    private static let entries = [TerminologyEntry(canonical: "Medicore", aliases: ["Medi Core"])]
    private static let transcript = "We use Medi Core for everything."

    /// A provider that cannot take a full-transcript echo must not be sent one: the
    /// pass would time out and bill for a result that is then discarded. The
    /// deterministic replacements still have to land, and the user has to be told
    /// which half of the correction ran.
    @MainActor
    func testProviderPassIsSkippedForAProviderThatCannotEchoTheTranscript() async {
        let stub = StubLLMProvider(displayName: "Claude Code", supportsFullTranscriptEcho: false)
        let service = TerminologyService(providerFactory: { stub })

        let result = await service.correct(Self.transcript, entries: Self.entries)

        XCTAssertEqual(result, "We use Medicore for everything.", "the regex pass must still run")
        XCTAssertTrue(stub.calls.isEmpty, "no generation may be billed for a pass we cannot use")
        XCTAssertEqual(
            service.warningMessage,
            TerminologyService.providerPassSkippedWarning(providerName: "Claude Code")
        )
    }

    /// The unchanged path: a local provider still gets the dictionary-replaced
    /// transcript, and its answer is what gets returned.
    @MainActor
    func testProviderPassRunsAndItsOutputIsUsedForALocalProvider() async {
        let corrected = "We use Medicore for everything, corrected by the model."
        let stub = StubLLMProvider(displayName: "Ollama", outcomes: [.success(corrected)])
        let service = TerminologyService(providerFactory: { stub })

        let result = await service.correct(Self.transcript, entries: Self.entries)

        XCTAssertEqual(result, corrected)
        XCTAssertNil(service.warningMessage)
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertTrue(
            stub.calls.first?.prompt.contains("We use Medicore for everything.") == true,
            "the pass receives the dictionary-replaced text, not the raw transcript"
        )
    }

    /// A transcript of `chars` characters made of `[mm:ss]` lines mentioning the alias.
    private static func longTranscript(chars: Int) -> String {
        var lines: [String] = []
        var total = 0
        var i = 0
        while total < chars {
            let line = String(format: "[%02d:%02d] Spreker %d: we gebruiken Medi Core voor punt %05d.", (i / 60) % 60, i % 60, i % 4, i)
            lines.append(line)
            total += line.count + 1
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    /// Past the largest context we run a local model at, the echo would come back
    /// missing the start of the meeting and still pass `looksLikeMangledOutput`.
    /// The pass must not run; the deterministic result stands, with a warning.
    @MainActor
    func testProviderPassIsSkippedWhenTheTranscriptIsTooLongToEchoWithinTheContext() async {
        let transcript = Self.longTranscript(chars: 60_000)
        let stub = StubLLMProvider(displayName: "Ollama", outcomes: [.success("should not be used")])
        let service = TerminologyService(providerFactory: { stub })

        let result = await service.correct(transcript, entries: Self.entries)

        XCTAssertTrue(stub.calls.isEmpty, "an echo that cannot fit the context must not be requested")
        XCTAssertEqual(result, TerminologyService.dictionaryReplace(transcript, entries: Self.entries))
        XCTAssertFalse(result.contains("Medi Core"), "the regex pass still ran")
        XCTAssertEqual(service.warningMessage, TerminologyService.providerPassTooLongWarning(providerName: "Ollama"))
    }

    /// A long transcript that still fits (prompt + echo + slack ≤ the cap) keeps the pass.
    @MainActor
    func testProviderPassStillRunsForALongTranscriptThatFitsTheContext() async {
        let transcript = Self.longTranscript(chars: 40_000)
        let replaced = TerminologyService.dictionaryReplace(transcript, entries: Self.entries)
        XCTAssertTrue(TerminologyService.providerPassFitsContext(
            prompt: TerminologyService.providerPassPrompt(transcript: replaced, entries: Self.entries)
        ))
        let stub = StubLLMProvider(displayName: "Ollama", outcomes: [.success(replaced)])
        let service = TerminologyService(providerFactory: { stub })

        let result = await service.correct(transcript, entries: Self.entries)

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.prompt, TerminologyService.providerPassPrompt(transcript: replaced, entries: Self.entries))
        XCTAssertEqual(result, replaced)
        XCTAssertNil(service.warningMessage)
    }

    /// The gate is `2 · budgetTokens(prompt) + slack ≤ ollamaMaxContextTokens`.
    func testProviderPassFitsContextBoundary() {
        let maxPromptTokens = (LLMPromptSupport.ollamaMaxContextTokens - LLMPromptSupport.contextSlackTokens) / 2
        let fits = String(repeating: "a", count: maxPromptTokens * LLMPromptSupport.budgetCharsPerToken)
        XCTAssertTrue(TerminologyService.providerPassFitsContext(prompt: fits))
        XCTAssertFalse(TerminologyService.providerPassFitsContext(prompt: fits + String(repeating: "a", count: LLMPromptSupport.budgetCharsPerToken)))
    }

    func testProviderPassTooLongWarningNamesTheProviderAndTheReplacementsThatRan() {
        let warning = TerminologyService.providerPassTooLongWarning(providerName: "Ollama")
        XCTAssertTrue(warning.contains("Ollama"), warning)
        XCTAssertTrue(warning.localizedCaseInsensitiveContains("deterministic replacements"), warning)
    }

    /// The skip warning has to name what the user still got; a bare "unavailable"
    /// would read as if the transcript had gone uncorrected.
    func testProviderPassSkippedWarningNamesTheProviderAndTheReplacementsThatRan() {
        let warning = TerminologyService.providerPassSkippedWarning(providerName: "Claude Code")
        XCTAssertTrue(warning.contains("Claude Code"), warning)
        XCTAssertTrue(warning.localizedCaseInsensitiveContains("deterministic replacements"), warning)
    }

    func testParseSkipsCommentsAndBlankLines() {
        let raw = """
        # Producten & techniek
        Medicore: Medi Core

        # Mensen
        Youri: Joeri, Jouri
        """
        let entries = TerminologyService.parse(raw)
        XCTAssertEqual(entries, [
            TerminologyEntry(canonical: "Medicore", aliases: ["Medi Core"]),
            TerminologyEntry(canonical: "Youri", aliases: ["Joeri", "Jouri"]),
        ])
    }

    // MARK: - Speaker prefixes

    private static let speakerTranscript = """
    [00:00] Youri: We use Medi Core for everything.
    [00:05] Others: Does Medi Core cover the agenda?
    [00:09] Youri: Yes.
    """

    /// An LLM echo that loses (or invents) a speaker prefix would silently
    /// re-attribute speech, so the deterministic text wins, with a warning.
    @MainActor
    func testLLMOutputDroppingSpeakerPrefixesFallsBackToDeterministic() async {
        let dropped = """
        [00:00] We use Medicore for everything.
        [00:05] Others: Does Medicore cover the agenda?
        [00:09] Youri: Yes.
        """
        let stub = StubLLMProvider(displayName: "Ollama", outcomes: [.success(dropped)])
        let service = TerminologyService(providerFactory: { stub })

        let result = await service.correct(
            Self.speakerTranscript,
            entries: Self.entries,
            knownSpeakers: ["Youri", "Others"]
        )

        XCTAssertEqual(result, """
        [00:00] Youri: We use Medicore for everything.
        [00:05] Others: Does Medicore cover the agenda?
        [00:09] Youri: Yes.
        """)
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(service.warningMessage, TerminologyService.speakerPrefixesChangedWarning)
    }

    @MainActor
    func testLLMOutputKeepingSpeakerPrefixesIsUsed() async {
        let corrected = """
        [00:00] Youri: We use Medicore for everything!
        [00:05] Others: Does Medicore cover the agenda?
        [00:09] Youri: Yes.
        """
        let stub = StubLLMProvider(displayName: "Ollama", outcomes: [.success(corrected)])
        let service = TerminologyService(providerFactory: { stub })

        let result = await service.correct(Self.speakerTranscript, entries: Self.entries, knownSpeakers: ["Youri", "Others"])

        XCTAssertEqual(result, corrected)
        XCTAssertNil(service.warningMessage)
    }

    /// The deterministic pass must not rewrite a speaker name that happens to be an alias.
    @MainActor
    func testDeterministicPassLeavesSpeakerPrefixesAlone() async {
        let stub = StubLLMProvider(displayName: "Claude Code", supportsFullTranscriptEcho: false)
        let service = TerminologyService(providerFactory: { stub })
        let entries = [TerminologyEntry(canonical: "Joeri", aliases: ["Youri"])]

        let result = await service.correct("[00:00] Youri: Youri said hi", entries: entries, knownSpeakers: ["Youri"])

        XCTAssertEqual(result, "[00:00] Youri: Joeri said hi")
    }

    /// A caller that already ran the deterministic pass (the labelled pipeline
    /// path) must be able to skip it: "Team Link: Link" is not idempotent.
    @MainActor
    func testSkippingTheDictionaryPassDoesNotReplaceTwice() async {
        let entries = [TerminologyEntry(canonical: "Team Link", aliases: ["Link"])]
        let once = TerminologyService.dictionaryReplace("link rocks", entries: entries)
        XCTAssertEqual(once, "Team Link rocks")
        XCTAssertEqual(TerminologyService.dictionaryReplace(once, entries: entries), "Team Team Link rocks",
                       "The hazard this guards against")

        let stub = StubLLMProvider(displayName: "Ollama", outcomes: [.success("[00:00] Youri: Team Link rocks!")])
        let service = TerminologyService(providerFactory: { stub })
        let result = await service.correct(
            "[00:00] Youri: Team Link rocks", entries: entries, knownSpeakers: ["Youri"], applyDictionary: false
        )

        XCTAssertEqual(result, "[00:00] Youri: Team Link rocks!")
        XCTAssertTrue(stub.calls.first?.prompt.contains("[00:00] Youri: Team Link rocks\n") == true
                      || stub.calls.first?.prompt.hasSuffix("[00:00] Youri: Team Link rocks") == true,
                      "The provider gets the text as handed in, not replaced again")

        let skipped = TerminologyService(providerFactory: { StubLLMProvider(supportsFullTranscriptEcho: false) })
        let fallback = await skipped.correct(
            "[00:00] Youri: Team Link rocks", entries: entries, knownSpeakers: ["Youri"], applyDictionary: false
        )
        XCTAssertEqual(fallback, "[00:00] Youri: Team Link rocks", "The fallback text is not replaced again either")
    }

    func testPrefixCheckIgnoresTextChanges() {
        let output = """
        [00:00] Youri: Completely different words here.
        [00:05] Others: Also changed.
        [00:09] Youri: Yes!
        """
        XCTAssertTrue(TerminologyService.speakerPrefixesPreserved(
            input: Self.speakerTranscript, output: output, knownSpeakers: ["Youri", "Others"]
        ))
        XCTAssertTrue(TerminologyService.speakerPrefixesPreserved(
            input: Self.speakerTranscript, output: output + "\n", knownSpeakers: ["Youri", "Others"]
        ), "A trailing newline is not a line")

        let swapped = output.replacingOccurrences(of: "[00:05] Others:", with: "[00:05] Youri:")
        XCTAssertFalse(TerminologyService.speakerPrefixesPreserved(
            input: Self.speakerTranscript, output: swapped, knownSpeakers: ["Youri", "Others"]
        ))
        let merged = "[00:00] Youri: We use Medicore.\n[00:05] Others: Does it? Yes."
        XCTAssertFalse(TerminologyService.speakerPrefixesPreserved(
            input: Self.speakerTranscript, output: merged, knownSpeakers: ["Youri", "Others"]
        ), "Merging lines changes the per-line sequence")
        let preamble = "Here is the transcript:\n" + output
        XCTAssertFalse(TerminologyService.speakerPrefixesPreserved(
            input: Self.speakerTranscript, output: preamble, knownSpeakers: ["Youri", "Others"]
        ))
    }
}
