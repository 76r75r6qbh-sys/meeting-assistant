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

    /// Shown when the lookup succeeded but returned nothing.
    ///
    /// For Claude Code this branch is unreachable by construction: the model list
    /// is static, so `ClaudeCLIProvider.fetchAvailableModels` either throws — which
    /// `SettingsView.refreshModels` routes into `modelsError`, an earlier branch —
    /// or returns a non-empty list. The string exists only as a defensive fallback.
    static func noModelsFound(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .omlx: return "No \(displayName(for: kind)) models were found at this endpoint yet."
        case .claudeCode: return "No Claude Code models are available. Check the CLI path above."
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
            return "Usage counts against your Claude subscription's limits rather than a paid API key, and each call is slower than a local model. Leave terminology correction off: it sends the whole transcript and expects the full text back, and a shortened reply overwrites your transcript."
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
}
