import XCTest
@testable import Casablanca

final class LLMProviderCopyTests: XCTestCase {
    /// Every provider kind. `LLMProviderKind` is not `CaseIterable`, so
    /// `testAllKindsIsExhaustive` is what keeps this list honest.
    private let allKinds: [LLMProviderKind] = [.ollama, .omlx, .claudeCode]

    private let localKinds: [LLMProviderKind] = [.ollama, .omlx]

    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Adding a case to `LLMProviderKind` makes the switch below non-exhaustive,
    /// so this file stops compiling until `allKinds` is extended — which is the
    /// point: every test here iterates that list.
    func testAllKindsIsExhaustive() {
        for kind in allKinds {
            switch kind {
            case .ollama, .omlx, .claudeCode: break
            }
        }
        XCTAssertEqual(allKinds.count, 3)
    }

    // MARK: - Every kind gets copy

    func testEveryEntryIsNonEmptyForEveryKind() {
        for kind in allKinds {
            XCTAssertFalse(LLMProviderCopy.displayName(for: kind).isEmpty, "displayName for \(kind)")
            XCTAssertFalse(LLMProviderCopy.locationFieldLabel(for: kind).isEmpty, "locationFieldLabel for \(kind)")
            XCTAssertFalse(LLMProviderCopy.modelLoadingLabel(for: kind).isEmpty, "modelLoadingLabel for \(kind)")
            XCTAssertFalse(LLMProviderCopy.noModelsFound(for: kind).isEmpty, "noModelsFound for \(kind)")
            XCTAssertFalse(LLMProviderCopy.modelNotAvailable(for: kind).isEmpty, "modelNotAvailable for \(kind)")
            XCTAssertFalse(LLMProviderCopy.summarizationFooter(for: kind).isEmpty, "summarizationFooter for \(kind)")
            XCTAssertFalse(LLMProviderCopy.privacySubtitle(for: kind).isEmpty, "privacySubtitle for \(kind)")

            let summaries = LLMProviderCopy.summariesFeature(for: kind)
            XCTAssertFalse(summaries.title.isEmpty, "summariesFeature title for \(kind)")
            XCTAssertFalse(summaries.subtitle.isEmpty, "summariesFeature subtitle for \(kind)")

            let step = LLMProviderCopy.llmStepHeader(for: kind)
            XCTAssertFalse(step.title.isEmpty, "llmStepHeader title for \(kind)")
            XCTAssertFalse(step.subtitle.isEmpty, "llmStepHeader subtitle for \(kind)")
        }
    }

    // MARK: - Caveats

    /// The Settings view hides the caveats caption when it is empty, so an
    /// accidental placeholder here would render a stray blank line.
    func testCaveatsAreEmptyForLocalProviders() {
        for kind in localKinds {
            XCTAssertEqual(LLMProviderCopy.caveats(for: kind), "", "caveats for \(kind)")
        }
    }

    func testCaveatsForClaudeCodeMentionSubscriptionLimitsAndTerminology() {
        let caveats = LLMProviderCopy.caveats(for: .claudeCode)
        XCTAssertFalse(caveats.isEmpty)
        XCTAssertTrue(
            caveats.contains("subscription"),
            "the subscription-billing caveat is the main reason this caption exists: \(caveats)"
        )
        XCTAssertTrue(
            caveats.contains("terminology correction"),
            "the terminology-correction warning must survive rewording: \(caveats)"
        )
    }

    // MARK: - Location field

    func testLocationFieldLabelIsCLIPathForClaudeCodeAndEndpointForLocalProviders() {
        XCTAssertEqual(LLMProviderCopy.locationFieldLabel(for: .claudeCode), "CLI path")
        for kind in localKinds {
            XCTAssertEqual(LLMProviderCopy.locationFieldLabel(for: kind), "Endpoint", "locationFieldLabel for \(kind)")
        }
    }

    // MARK: - Agreement with the providers

    /// The provider owns the name used in its error messages; this enum owns the
    /// name used in the captions around them. They appear side by side, so they
    /// must not drift.
    func testDisplayNameAgreesWithTheProviderItDescribes() {
        for kind in allKinds {
            let defaults = makeDefaults()
            AppPreferences.setLLMProvider(kind, in: defaults)
            // Construction only — no request and no subprocess is ever run here.
            let provider = LLMProviderFactory.current(defaults: defaults)
            XCTAssertEqual(
                provider.displayName,
                LLMProviderCopy.displayName(for: kind),
                "\(type(of: provider)).displayName disagrees with LLMProviderCopy.displayName(for: .\(kind))"
            )
        }
    }

    func testDisplayNamesAreTheExpectedStrings() {
        XCTAssertEqual(LLMProviderCopy.displayName(for: .ollama), "Ollama")
        XCTAssertEqual(LLMProviderCopy.displayName(for: .omlx), "oMLX")
        XCTAssertEqual(LLMProviderCopy.displayName(for: .claudeCode), "Claude Code")
    }

    // MARK: - Honesty of the Claude Code copy

    /// With Claude Code selected the transcript is sent to Anthropic. Copy that
    /// still promises a local model, or repeats the "nothing is sent to the
    /// cloud" line the local providers earn, would be a false privacy claim.
    func testClaudeCodeCopyMakesNoLocalityClaims() {
        let strings = [
            "summarizationFooter": LLMProviderCopy.summarizationFooter(for: .claudeCode),
            "privacySubtitle": LLMProviderCopy.privacySubtitle(for: .claudeCode),
        ]
        for (entry, text) in strings {
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains("local"),
                "\(entry) claims locality: \(text)"
            )
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains("Nothing is sent to the cloud"),
                "\(entry) repeats the local-only privacy promise: \(text)"
            )
        }
    }

    /// The honest version has to say where the transcript goes, not just omit
    /// the false claim.
    func testClaudeCodePrivacySubtitleSaysTheTranscriptLeavesTheMac() {
        let subtitle = LLMProviderCopy.privacySubtitle(for: .claudeCode)
        XCTAssertTrue(subtitle.contains("Anthropic"), "privacySubtitle should name the recipient: \(subtitle)")
    }

    /// The local providers keep the wording onboarding shipped with; a
    /// provider-aware refactor must not quietly reword the default path.
    func testLocalProviderOnboardingCopyIsUnchanged() {
        for kind in localKinds {
            XCTAssertEqual(
                LLMProviderCopy.privacySubtitle(for: kind),
                "Everything stays on your Mac — recording, transcription and summaries run locally. Nothing is sent to the cloud."
            )
            XCTAssertEqual(LLMProviderCopy.summariesFeature(for: kind).title, "Private summaries")
            XCTAssertEqual(LLMProviderCopy.summariesFeature(for: kind).subtitle, "A local LLM drafts your notes.")
            XCTAssertEqual(LLMProviderCopy.llmStepHeader(for: kind).title, "Connect your local LLM")
            XCTAssertEqual(
                LLMProviderCopy.llmStepHeader(for: kind).subtitle,
                "Casablanca uses a local language model to draft summaries. Verify it is reachable below."
            )
        }
    }
}
