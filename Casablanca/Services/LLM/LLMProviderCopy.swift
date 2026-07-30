import Foundation

/// The user-facing wording that changes with the selected `LLMProviderKind`.
///
/// It exists for two reasons: Settings and Onboarding need the same
/// provider-conditional sentences, and a string assembled inside a SwiftUI
/// `body` cannot be asserted on. Both problems disappear once the sentences
/// live here.
///
/// This is deliberately not a general-purpose localization layer — add an entry
/// only when a view actually needs one.
///
/// The `.claudeCode` wording must never borrow the locality or privacy claims
/// that are true of the two local providers: with Claude Code selected, the
/// transcript leaves the Mac. `LLMProviderCopyTests` guards that.
enum LLMProviderCopy {
    /// The provider's name as the user sees it.
    ///
    /// Must stay equal to the matching `LLMProvider.displayName`. Both strings
    /// surface in the same screens — provider error messages come from the
    /// provider, captions from here — so a mismatch reads as a bug.
    /// `LLMProviderCopyTests` asserts the agreement.
    static func displayName(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama: return "Ollama"
        case .omlx: return "oMLX"
        case .claudeCode: return "Claude Code"
        }
    }

    /// Label for the field holding the endpoint URL, or the CLI path.
    static func locationFieldLabel(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx: return "Endpoint"
        // Not a URL: this field carries the path to the `claude` binary.
        case .claudeCode: return "CLI path"
        }
    }

    /// Shown while the model list loads.
    static func modelLoadingLabel(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx: return "Loading installed \(displayName(for: kind)) models…"
        // Claude Code has no model-list command; the lookup is a CLI reachability probe.
        case .claudeCode: return "Checking the Claude Code CLI…"
        }
    }

    /// Shown when the model list is empty.
    ///
    /// For Claude Code that does not mean the lookup came back empty — the model
    /// list is static, so `ClaudeCLIProvider.fetchAvailableModels` either throws
    /// (routed into `modelsError`, an earlier branch) or returns three entries.
    /// What it does mean is "nothing has been checked yet": `SettingsView` opens
    /// with an empty list and runs `refreshModels()` from `.task`, i.e. after the
    /// first body evaluation, so this branch renders once on every Settings open.
    /// Hence the loading label rather than a diagnosis — telling the user to check
    /// a path that has not been tried yet would send them after a non-problem.
    static func noModelsFound(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx: return "No \(displayName(for: kind)) models were found at this endpoint yet."
        case .claudeCode: return modelLoadingLabel(for: kind)
        }
    }

    /// Suffix marking a model in the picker that the provider did not report.
    static func modelUnavailableSuffix(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx: return "(not installed)"
        // Nothing is installed here; the model is simply not one Claude Code offers.
        case .claudeCode: return "(unavailable)"
        }
    }

    /// Shown when the configured model isn't among the ones found.
    static func modelNotAvailable(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx:
            return "The current model is not installed at this endpoint. Pick one of the detected models above."
        case .claudeCode:
            return "That model isn't one Claude Code offers. Pick one of the models above."
        }
    }

    /// Footer explaining where summarization runs.
    static func summarizationFooter(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx:
            return "Casablanca loads the installed models from \(displayName(for: kind)) so summarization uses a valid local model."
        case .claudeCode:
            return "Casablanca runs the Claude Code CLI in headless mode, so summaries are drafted by Claude rather than a model on this Mac."
        }
    }

    /// Provider-specific caveats; empty when there are none. Callers must not
    /// render an empty caption.
    static func caveats(for kind: LLMProviderKind) -> String {
        switch kind {
        // A model on this Mac costs nothing per call and has no shared limits.
        case .ollama, .omlx: return ""
        case .claudeCode:
            return "Usage counts against your Claude subscription's limits. There is no API key and no per-call charge, and each call is slower than a local model."
        }
    }

    /// Caveat for the terminology-correction section; empty when there is none.
    ///
    /// Lives apart from `caveats` because it warns about a *different* toggle: it
    /// belongs next to the terminology switch, not three sections up under
    /// summarization, where a user who had the toggle on before switching provider
    /// would never look.
    static func terminologyCaveat(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx: return ""
        case .claudeCode:
            return "With Claude Code selected, only the find/replace runs. The model pass is skipped because it would send the whole transcript and wait for the full text back, which does not finish in time."
        }
    }

    /// Onboarding step 1 privacy line.
    static func privacySubtitle(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx:
            return "Everything stays on your Mac — recording, transcription and summaries run locally. Nothing is sent to the cloud."
        case .claudeCode:
            return "Recording and transcription stay on your Mac. Summaries are drafted by Claude Code, so the transcript is sent to Anthropic."
        }
    }

    /// Onboarding step 1 "summaries" feature row.
    static func summariesFeature(for kind: LLMProviderKind) -> (title: String, subtitle: String) {
        switch kind {
        case .ollama, .omlx:
            return (title: "Private summaries", subtitle: "A local LLM drafts your notes.")
        case .claudeCode:
            return (title: "Claude Code summaries", subtitle: "Claude drafts your notes from the transcript.")
        }
    }

    /// Onboarding step 4 header.
    static func llmStepHeader(for kind: LLMProviderKind) -> (title: String, subtitle: String) {
        switch kind {
        case .ollama, .omlx:
            return (
                title: "Connect your local LLM",
                subtitle: "Casablanca uses a local language model to draft summaries. Verify it is reachable below."
            )
        case .claudeCode:
            return (
                title: "Connect Claude Code",
                subtitle: "Casablanca runs the Claude Code CLI to draft summaries. Verify it is reachable below."
            )
        }
    }

    /// Onboarding step 4's closing line, pointing at where the settings live.
    ///
    /// Provider-aware only because the field it names is not the same field: for
    /// Claude Code the step above it is labelled "CLI path", so calling it an
    /// endpoint eight lines later describes a control that is not on screen.
    static func settingsChangeHint(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx:
            return "Change the provider, endpoint and model anytime in Settings → AI."
        case .claudeCode:
            return "Change the provider, CLI path and model anytime in Settings → AI."
        }
    }

    /// Step 4's success line, once the provider answered the model lookup.
    static func reachableSummary(modelCount: Int, for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx:
            return "\(displayName(for: kind)) is reachable — \(modelCount) model\(modelCount == 1 ? "" : "s") installed."
        case .claudeCode:
            // Nothing is installed for Claude Code — the CLI offers a fixed set of
            // models. That set has three entries, so the singular never occurs and
            // this branch does not carry a singular form.
            return "\(displayName(for: kind)) is reachable — \(modelCount) models available."
        }
    }
}
