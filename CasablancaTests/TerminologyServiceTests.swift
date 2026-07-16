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
}
