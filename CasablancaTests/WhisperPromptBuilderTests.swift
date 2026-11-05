import XCTest
@testable import Casablanca

final class WhisperPromptBuilderTests: XCTestCase {
    /// One token per character, so a token count is a character count and the
    /// tokens decode back to the exact string. Whisper's real special tokens
    /// start at 50257, far above any scalar used here.
    private static let specialTokenBegin = 50_257

    private static func encodeByCharacter(_ text: String) -> [Int] {
        text.unicodeScalars.map { Int($0.value) }
    }

    private static func decodeByCharacter(_ tokens: [Int]) -> String {
        String(String.UnicodeScalarView(tokens.compactMap { Unicode.Scalar(UInt32($0)) }))
    }

    // MARK: - Terms

    func testTermsAreCanonicalInListOrder() {
        let raw = "Wegiz: wegis, weggis\nBgZ\nMedicore"
        XCTAssertEqual(WhisperPromptBuilder.terms(enabled: true, raw: raw), ["Wegiz", "BgZ", "Medicore"])
    }

    func testTermsDedupedCaseInsensitivelyKeepingFirstSpelling() {
        let raw = "BgZ\nMedicore\nbgz: bgee\nMEDICORE"
        XCTAssertEqual(WhisperPromptBuilder.terms(enabled: true, raw: raw), ["BgZ", "Medicore"])
    }

    func testDisabledGivesNoTerms() {
        XCTAssertEqual(WhisperPromptBuilder.terms(enabled: false, raw: "Wegiz\nBgZ"), [])
        XCTAssertEqual(WhisperPromptBuilder.terms(enabled: true, raw: ""), [])
        XCTAssertEqual(WhisperPromptBuilder.terms(enabled: true, raw: "# only a comment\n   \n"), [])
    }

    // MARK: - Tokens

    func testMaxPromptTokensMatchesWhisperContext() {
        // Whisper's text context is 448 tokens; WhisperKit keeps at most
        // n_text_ctx/2 − 1 of a prompt.
        XCTAssertEqual(WhisperPromptBuilder.maxPromptTokens, 223)
    }

    func testTokensNeverExceedLimit() {
        let terms = (1...300).map { "Term\($0)" }
        let tokens = WhisperPromptBuilder.tokens(
            for: terms,
            encode: Self.encodeByCharacter,
            specialTokenBegin: Self.specialTokenBegin
        )
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertLessThanOrEqual(tokens.count, 223)
    }

    func testWholeTermsOnly() {
        let terms = (1...300).map { "Term\($0)" }
        let tokens = WhisperPromptBuilder.tokens(
            for: terms,
            encode: Self.encodeByCharacter,
            specialTokenBegin: Self.specialTokenBegin
        )
        let decoded = Self.decodeByCharacter(tokens)

        // The decoded prompt is exactly the first k terms, never a cut one —
        // and k is the largest that fits.
        let k = (1...terms.count).last { " " + terms.prefix($0).joined(separator: ", ") == decoded }
        XCTAssertNotNil(k, "decoded prompt does not end at a term boundary: \(decoded)")
        if let k {
            let next = " " + terms.prefix(k + 1).joined(separator: ", ")
            XCTAssertGreaterThan(next.unicodeScalars.count, 223, "a longer whole-term prompt would have fit")
        }
    }

    func testAllTermsUsedWhenTheyFit() {
        let tokens = WhisperPromptBuilder.tokens(
            for: ["Wegiz", "BgZ", "Medicore"],
            encode: Self.encodeByCharacter,
            specialTokenBegin: Self.specialTokenBegin
        )
        XCTAssertEqual(Self.decodeByCharacter(tokens), " Wegiz, BgZ, Medicore")
    }

    func testSpecialTokensFilteredBeforeCounting() {
        // An encoder that wraps every encoding in two special tokens, as some
        // tokenizers add BOS/EOS. With a limit equal to the text length the
        // prompt only fits if the special tokens are not counted.
        let encode: (String) -> [Int] = { text in
            [Self.specialTokenBegin + 5] + Self.encodeByCharacter(text) + [Self.specialTokenBegin]
        }
        let text = " Wegiz, BgZ"
        let tokens = WhisperPromptBuilder.tokens(
            for: ["Wegiz", "BgZ"],
            encode: encode,
            specialTokenBegin: Self.specialTokenBegin,
            limit: text.unicodeScalars.count
        )
        XCTAssertEqual(Self.decodeByCharacter(tokens), text)
        XCTAssertTrue(tokens.allSatisfy { $0 < Self.specialTokenBegin })
    }

    func testNoTermsOrFirstTermTooLongGivesNoPrompt() {
        XCTAssertEqual(
            WhisperPromptBuilder.tokens(for: [], encode: Self.encodeByCharacter, specialTokenBegin: Self.specialTokenBegin),
            []
        )
        XCTAssertEqual(
            WhisperPromptBuilder.tokens(
                for: ["Averyverylongterm", "B"],
                encode: Self.encodeByCharacter,
                specialTokenBegin: Self.specialTokenBegin,
                limit: 5
            ),
            []
        )
    }

    // MARK: - Prompt echo

    func testPromptEchoDetected() {
        let terms = ["Wegiz", "BgZ", "Medicore", "Orchestra", "Topdesk"]
        // The whole prompt, in Whisper's own punctuation and casing.
        XCTAssertTrue(WhisperPromptBuilder.isPromptEcho(" Wegiz, BgZ, Medicore, Orchestra, Topdesk.", terms: terms))
        XCTAssertTrue(WhisperPromptBuilder.isPromptEcho("wegiz bgz medicore orchestra topdesk", terms: terms))
        // A long enough leading part of it.
        XCTAssertTrue(WhisperPromptBuilder.isPromptEcho("Wegiz, BgZ, Medicore, Orchestra", terms: terms))
    }

    func testNormalSegmentNotEcho() {
        let terms = ["Wegiz", "BgZ", "Medicore", "Orchestra", "Topdesk"]
        XCTAssertFalse(WhisperPromptBuilder.isPromptEcho("We moeten de Wegiz BgZ koppeling testen.", terms: terms))
        // A short prefix is a legitimate utterance ("Wegiz, BgZ."), not an echo.
        XCTAssertFalse(WhisperPromptBuilder.isPromptEcho("Wegiz, BgZ.", terms: terms))
        XCTAssertFalse(WhisperPromptBuilder.isPromptEcho("", terms: terms))
        XCTAssertFalse(WhisperPromptBuilder.isPromptEcho("Wegiz, BgZ, Medicore, Orchestra, Topdesk", terms: []))
    }
}
