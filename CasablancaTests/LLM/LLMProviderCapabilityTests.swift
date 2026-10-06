import XCTest
@testable import Casablanca

/// The two capability properties on `LLMProvider` exist because the AI call sites
/// were all written for a free, fast, local model. These tests pin what each
/// provider claims, and that the defaults leave the local providers untouched.
final class LLMProviderCapabilityTests: XCTestCase {

    /// Construction only — no request is ever issued, so the shared session is fine.
    private func makeOllama() -> OllamaProvider {
        OllamaProvider(endpoint: "http://localhost:11434", model: "llama3.2", urlSession: .shared)
    }

    private func makeOMLX() -> OMLXProvider {
        OMLXProvider(endpoint: "http://localhost:8000/v1", model: "m", urlSession: .shared)
    }

    private func makeClaude() -> ClaudeCLIProvider {
        // Construction only — no subprocess is spawned by reading these properties.
        ClaudeCLIProvider(endpoint: "/tmp/never-run/claude", model: "sonnet", runner: FakeCommandRunner.succeeding())
    }

    // MARK: - preferredTimeout

    /// A local model needs no opinion here: the call sites' own numbers were chosen
    /// for it, and the protocol default must keep it that way.
    func testLocalProvidersHaveNoTimeoutPreference() {
        XCTAssertNil(makeOllama().preferredTimeout)
        XCTAssertNil(makeOMLX().preferredTimeout)
    }

    func testClaudeCodePrefersALongerTimeoutThanTheCallSitesDefault() {
        guard let preferred = makeClaude().preferredTimeout else {
            return XCTFail("Claude Code must state a timeout; the call sites' 120s is sized for a local model")
        }
        XCTAssertGreaterThan(
            preferred,
            120,
            "a 3500-token structured summary from a frontier model does not finish in the callers' 120s"
        )
    }

    /// The resolution rule the call sites rely on: the provider wins when it has a
    /// preference, and the caller's own number survives untouched when it does not.
    func testTimeoutOrDefaultPrefersTheProviderThenFallsBackToTheCaller() {
        XCTAssertEqual(makeOllama().timeout(orDefault: 120), 120)
        XCTAssertEqual(makeOMLX().timeout(orDefault: 120), 120)
        XCTAssertEqual(makeClaude().timeout(orDefault: 120), makeClaude().preferredTimeout)
    }

    func testTimeoutOrDefaultIsUnaffectedByTheCallerWhenTheProviderHasAPreference() {
        // Whatever the caller asks for, a provider with a preference overrides it —
        // otherwise a second call site could quietly reintroduce a too-short budget.
        XCTAssertEqual(makeClaude().timeout(orDefault: 5), makeClaude().preferredTimeout)
    }

    // MARK: - supportsFullTranscriptEcho

    /// Terminology correction's provider pass sends the whole transcript and expects
    /// it echoed back. That is free on this Mac and billed-and-slow anywhere else.
    func testOnlyLocalProvidersAcceptAFullTranscriptEcho() {
        XCTAssertTrue(makeOllama().supportsFullTranscriptEcho)
        XCTAssertTrue(makeOMLX().supportsFullTranscriptEcho)
        XCTAssertFalse(makeClaude().supportsFullTranscriptEcho)
    }

    /// No provider may *shorten* what the call site asked for. The call sites' own
    /// numbers were sized for the fastest case — a model already resident on this Mac
    /// — so a preference below one of them could only ever cut off work that was
    /// going to succeed, and (at the retrying call sites) bill for the attempts.
    func testNoProviderShortensTheCallSitesTimeout() {
        for kind in LLMProviderKind.allCases {
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            AppPreferences.setLLMProvider(kind, in: defaults)

            // Construction only; no request and no subprocess runs here.
            let provider = LLMProviderFactory.current(defaults: defaults)
            for callSiteDefault in [120.0, TerminologyService.estimatedTimeout(forTranscriptLength: 80_000)] {
                XCTAssertGreaterThanOrEqual(
                    provider.timeout(orDefault: callSiteDefault),
                    callSiteDefault,
                    "\(kind) shortens a caller's \(callSiteDefault)s budget"
                )
            }
        }
    }
}
