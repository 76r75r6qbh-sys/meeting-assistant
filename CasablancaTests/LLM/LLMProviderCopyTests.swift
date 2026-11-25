import XCTest
@testable import Casablanca

final class LLMProviderCopyTests: XCTestCase {
    /// Every provider kind. Derived from `CaseIterable` rather than hand-listed, so
    /// a new kind is covered by every test here the moment it is declared.
    private let allKinds = LLMProviderKind.allCases

    private let localKinds: [LLMProviderKind] = [.ollama, .omlx]

    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Every kind gets copy

    func testEveryEntryIsNonEmptyForEveryKind() {
        for kind in allKinds {
            XCTAssertFalse(LLMProviderCopy.displayName(for: kind).isEmpty, "displayName for \(kind)")
            XCTAssertFalse(LLMProviderCopy.locationFieldLabel(for: kind).isEmpty, "locationFieldLabel for \(kind)")
            XCTAssertFalse(LLMProviderCopy.modelLoadingLabel(for: kind).isEmpty, "modelLoadingLabel for \(kind)")
            XCTAssertFalse(LLMProviderCopy.noModelsFound(for: kind).isEmpty, "noModelsFound for \(kind)")
            XCTAssertFalse(LLMProviderCopy.modelNotAvailable(for: kind).isEmpty, "modelNotAvailable for \(kind)")
            XCTAssertFalse(LLMProviderCopy.modelUnavailableSuffix(for: kind).isEmpty, "modelUnavailableSuffix for \(kind)")
            XCTAssertFalse(LLMProviderCopy.summarizationFooter(for: kind).isEmpty, "summarizationFooter for \(kind)")
            XCTAssertFalse(LLMProviderCopy.privacySubtitle(for: kind).isEmpty, "privacySubtitle for \(kind)")
            XCTAssertFalse(LLMProviderCopy.settingsChangeHint(for: kind).isEmpty, "settingsChangeHint for \(kind)")

            let summaries = LLMProviderCopy.summariesFeature(for: kind)
            XCTAssertFalse(summaries.title.isEmpty, "summariesFeature title for \(kind)")
            XCTAssertFalse(summaries.subtitle.isEmpty, "summariesFeature subtitle for \(kind)")

            let step = LLMProviderCopy.llmStepHeader(for: kind)
            XCTAssertFalse(step.title.isEmpty, "llmStepHeader title for \(kind)")
            XCTAssertFalse(step.subtitle.isEmpty, "llmStepHeader subtitle for \(kind)")

            XCTAssertFalse(
                LLMProviderCopy.reachableSummary(modelCount: 3, for: kind).isEmpty,
                "reachableSummary for \(kind)"
            )
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

    func testCaveatsForClaudeCodeMentionSubscriptionLimits() {
        let caveats = LLMProviderCopy.caveats(for: .claudeCode)
        XCTAssertFalse(caveats.isEmpty)
        XCTAssertTrue(
            caveats.contains("subscription"),
            "the subscription-billing caveat is the main reason this caption exists: \(caveats)"
        )
    }

    /// The terminology warning deliberately does NOT live in `caveats`: that caption
    /// renders under summarization, three sections above the toggle it is about, so a
    /// user who already had the toggle on and then switched provider never saw it.
    func testTerminologyCaveatIsSeparateFromTheSummarizationCaveats() {
        XCTAssertFalse(
            LLMProviderCopy.caveats(for: .claudeCode).localizedCaseInsensitiveContains("terminology"),
            "the terminology warning belongs next to the terminology toggle"
        )
        for kind in localKinds {
            XCTAssertEqual(LLMProviderCopy.terminologyCaveat(for: kind), "", "terminologyCaveat for \(kind)")
        }
    }

    /// The code now skips the provider pass rather than relying on the user to turn
    /// the toggle off, so the caption has to describe what happens — not give an
    /// instruction that no longer applies.
    func testTerminologyCaveatForClaudeCodeDescribesTheSkipRatherThanAskingTheUserToActInstead() {
        let caveat = LLMProviderCopy.terminologyCaveat(for: .claudeCode)
        XCTAssertFalse(caveat.isEmpty)
        XCTAssertTrue(
            caveat.localizedCaseInsensitiveContains("skipped"),
            "the caption must say the model pass is skipped: \(caveat)"
        )
        XCTAssertTrue(
            caveat.localizedCaseInsensitiveContains("find/replace"),
            "and that the deterministic half still runs: \(caveat)"
        )
        for phrase in ["Leave terminology correction off", "Keep terminology correction off", "turn it off"] {
            XCTAssertFalse(
                caveat.localizedCaseInsensitiveContains(phrase),
                "stale instruction to disable the toggle: \(caveat)"
            )
        }
    }

    // MARK: - First paint, before anything has been checked

    /// `SettingsView` opens with an empty model list and only runs `refreshModels()`
    /// from `.task`, so this string renders once on every Settings open — before the
    /// CLI has been looked at. Telling the user to check the path at that moment
    /// sends them after a problem that may not exist.
    func testNoModelsFoundForClaudeCodeDoesNotBlameThePathBeforeAnythingWasChecked() {
        let text = LLMProviderCopy.noModelsFound(for: .claudeCode)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(
            text.localizedCaseInsensitiveContains("check the"),
            "not a diagnosis: nothing has been probed yet when this first renders: \(text)"
        )
        XCTAssertEqual(text, LLMProviderCopy.modelLoadingLabel(for: .claudeCode))
    }

    // MARK: - Onboarding step 4 footer

    /// Step 4 labels the field above this line "CLI path" for Claude Code, so calling
    /// it an endpoint eight lines later names a control that is not on screen.
    func testSettingsChangeHintNamesTheFieldTheStepActuallyShows() {
        XCTAssertEqual(
            LLMProviderCopy.settingsChangeHint(for: .claudeCode),
            "Change the provider, CLI path and model anytime in Settings → AI."
        )
        XCTAssertTrue(
            LLMProviderCopy.settingsChangeHint(for: .claudeCode)
                .contains(LLMProviderCopy.locationFieldLabel(for: .claudeCode)),
            "the hint must name the same field label the step renders"
        )
        XCTAssertFalse(
            LLMProviderCopy.settingsChangeHint(for: .claudeCode).localizedCaseInsensitiveContains("endpoint")
        )
    }

    // MARK: - Location field

    func testLocationFieldLabelIsCLIPathForClaudeCodeAndEndpointForLocalProviders() {
        XCTAssertEqual(LLMProviderCopy.locationFieldLabel(for: .claudeCode), "CLI path")
        for kind in localKinds {
            XCTAssertEqual(LLMProviderCopy.locationFieldLabel(for: kind), "Endpoint", "locationFieldLabel for \(kind)")
        }
    }

    // MARK: - Model picker suffix

    /// The suffix sits next to `modelNotAvailable`, which for a local provider says
    /// the model "is not installed at this endpoint" — so the suffix has to agree.
    func testModelUnavailableSuffixMatchesTheReasonTheModelIsMissing() {
        for kind in localKinds {
            XCTAssertEqual(
                LLMProviderCopy.modelUnavailableSuffix(for: kind),
                "(not installed)",
                "modelUnavailableSuffix for \(kind)"
            )
        }
        // Nothing is installed under Claude Code; the model is just not on offer.
        XCTAssertEqual(LLMProviderCopy.modelUnavailableSuffix(for: .claudeCode), "(unavailable)")
    }

    // MARK: - Step 4 success line

    /// Onboarding built this sentence inline before it moved here. These are the
    /// exact strings the old interpolation produced, singular and plural, so an
    /// Ollama or oMLX user cannot notice the move.
    func testReachableSummaryIsUnchangedForLocalProviders() {
        XCTAssertEqual(
            LLMProviderCopy.reachableSummary(modelCount: 1, for: .ollama),
            "Ollama is reachable — 1 model installed."
        )
        XCTAssertEqual(
            LLMProviderCopy.reachableSummary(modelCount: 3, for: .ollama),
            "Ollama is reachable — 3 models installed."
        )
        XCTAssertEqual(
            LLMProviderCopy.reachableSummary(modelCount: 1, for: .omlx),
            "oMLX is reachable — 1 model installed."
        )
        XCTAssertEqual(
            LLMProviderCopy.reachableSummary(modelCount: 3, for: .omlx),
            "oMLX is reachable — 3 models installed."
        )
    }

    /// Claude Code installs nothing, so the line must not say "installed". The
    /// count is passed through rather than hardcoded even though the CLI's static
    /// list always has three entries.
    func testReachableSummaryForClaudeCodeSaysAvailableNotInstalled() {
        XCTAssertEqual(
            LLMProviderCopy.reachableSummary(modelCount: 3, for: .claudeCode),
            "Claude Code is reachable — 3 models available."
        )
        // A second count, so hardcoding "3" into the branch cannot pass this test —
        // which is what the comment above claims the branch does not do.
        XCTAssertEqual(
            LLMProviderCopy.reachableSummary(modelCount: 2, for: .claudeCode),
            "Claude Code is reachable — 2 models available."
        )
        XCTAssertFalse(
            LLMProviderCopy.reachableSummary(modelCount: 3, for: .claudeCode).contains("installed"),
            "nothing is installed under Claude Code"
        )
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
    ///
    /// `caveats` is deliberately absent: "slower than a local model" is a legitimate
    /// comparison against the other providers, not a claim about this one.
    func testClaudeCodeCopyMakesNoLocalityClaims() {
        let stepHeader = LLMProviderCopy.llmStepHeader(for: .claudeCode)
        let summaries = LLMProviderCopy.summariesFeature(for: .claudeCode)
        let strings = [
            "summarizationFooter": LLMProviderCopy.summarizationFooter(for: .claudeCode),
            "privacySubtitle": LLMProviderCopy.privacySubtitle(for: .claudeCode),
            "llmStepHeader.title": stepHeader.title,
            "llmStepHeader.subtitle": stepHeader.subtitle,
            "summariesFeature.title": summaries.title,
            "summariesFeature.subtitle": summaries.subtitle,
            "reachableSummary": LLMProviderCopy.reachableSummary(modelCount: 3, for: .claudeCode),
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
            // Moved out of the view verbatim when Claude Code needed "CLI path" here.
            XCTAssertEqual(
                LLMProviderCopy.settingsChangeHint(for: kind),
                "Change the provider, endpoint and model anytime in Settings → AI."
            )
        }
    }
}
