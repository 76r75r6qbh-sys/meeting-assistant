import Foundation
import OSLog
import Observation
import SwiftData

enum SummarizationError: LocalizedError {
    case invalidEndpoint(provider: String)
    case missingSourceMaterial
    case requestFailed(String)
    case emptyResponse(provider: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let provider):
            return "The \(provider) endpoint is invalid. Update it in Settings."
        case .missingSourceMaterial:
            return "Casablanca needs a transcript or notes before it can summarize the meeting."
        case .requestFailed(let message):
            return message
        case .emptyResponse(let provider):
            return "\(provider) returned an empty summary."
        }
    }
}

@MainActor
@Observable
final class SummarizationService {
    static let defaultPromptTemplate = """
    You are a meeting assistant creating structured, high-signal meeting notes.

    Write the notes in the dominant language of the transcript (Dutch transcript -> Dutch notes, English transcript -> English notes).

    Use only the information provided below. If something is unclear or missing, leave it out instead of guessing.

    The transcript comes from machine speech recognition and may misspell names of people, companies and products. Correct obvious mistranscriptions using the terminology list and the participants list. Never invent names, and never comment on transcript quality in the notes.

    Structure the notes as follows:

    1. Start with a single `# Summary` heading (Dutch: `# Samenvatting`) followed by a 2-4 sentence paragraph: what the meeting was about and its main outcome.
    2. Then 2-5 thematic sections, each with a descriptive `## <theme>` heading, containing a short intro sentence and/or `- **subtopic:** detail` bullets. Capture the reasoning behind conclusions, not just the conclusions.
    3. If the meeting discussed planning across dates, weeks or months, add a `## Planning` section with chronological bullets: `- **<period>** — <milestone or activity>`.
    4. If hiring or staffing was discussed, add a `## Personele zaken` (English: `## Personnel`) section.
    5. End with these four sections, always present, in this order. Use exactly these headings — Dutch notes / English notes:
       `## Besluiten` / `## Decisions`
       `## Actiepunten` / `## Action Items`
       `## Risico's en blockers` / `## Risks and Blockers`
       `## Opvolging` / `## Follow-ups`

    Rules for the four closing sections:
    - Every item is a `- ` bullet. If a section has no items, keep the heading with nothing below it.
    - Decisions include their stated rationale.
    - Each action item is one bullet formatted `- **<owner>** — <action>`. Resolve the owner against the participants list; use the person's name, never "me" or "I". If no owner was stated, use `- **?** — <action>`.
    - Omit optional sections that have nothing meaningful. Never add sections about the transcript itself.

    {{terminology_list}}

    Meeting title: {{title}}
    Scheduled time: {{scheduled_time}}
    Participants: {{participants}}

    Transcript:
    {{transcript}}

    Freeform notes:
    {{freeform_notes}}
    """

    /// Upper bound on generated summary length when thinking is OFF. Local models
    /// can otherwise ramble or loop for thousands of tokens on a short transcript.
    /// Kept as a forwarding alias to the shared helper so existing callers
    /// (PrepEditorView, tests) keep working.
    static var maxSummaryTokens: Int { LLMPromptSupport.cappedOutputTokens }

    /// Removes chain-of-thought blocks reasoning models emit before their answer.
    /// Forwards to the shared `LLMPromptSupport.stripReasoning` so the summary,
    /// prep and chat flows all use one copy.
    static func stripReasoning(_ text: String) -> String {
        LLMPromptSupport.stripReasoning(text)
    }

    /// Where the summarization pipeline currently is. Drives `statusMessage`.
    enum SummarizationPhase: Equatable {
        case idle
        case sending
        case retrying(attempt: Int, maxAttempts: Int)
        case parsing
    }

    private(set) var isSummarizing = false
    private(set) var phase: SummarizationPhase = .idle

    /// Human-readable status derived from `phase`. Kept as a computed property so
    /// existing views that read `statusMessage` keep working. `.idle` maps to "",
    /// which RecordedMeetingView turns into its "Generating summary..." fallback.
    var statusMessage: String {
        switch phase {
        case .idle:
            return ""
        case .sending:
            return "Sending transcript and notes to \(providerDisplayName)..."
        case .retrying(let attempt, let maxAttempts):
            return "\(providerDisplayName) request failed, retrying (\(attempt)/\(maxAttempts))..."
        case .parsing:
            return "Processing summary…"
        }
    }

    /// Display name of the provider for the in-flight summarization, captured so
    /// `statusMessage` can name it without re-reading preferences off-thread.
    private var providerDisplayName = "the model"

    var errorMessage: String?
    var warningMessage: String?

    /// The meeting currently being summarized in the background (nil when idle).
    /// Lets list rows show a spinner on the specific meeting being processed.
    private(set) var summarizingMeetingID: UUID?

    /// Wall-clock time the current summarization began (nil when idle). Used by
    /// the pipeline-status UI to show elapsed time for the indeterminate
    /// summarization stage.
    private(set) var summarizationStartedAt: Date?

    private var backgroundTask: Task<Void, Never>?

    /// Summarize in a service-owned task that is NOT tied to any view's
    /// lifecycle, so it keeps running if the user navigates away. On success it
    /// stores the summary on the meeting and silently saves newly extracted
    /// action items as meeting to-dos (deduped), then persists.
    func summarizeInBackground(meeting: Meeting, modelContext: ModelContext) {
        // If a summary is already in flight, do nothing — never cancel/restart a
        // running summary (e.g. when the view re-appears and re-triggers this).
        guard !isSummarizing else { return }
        // Mark busy synchronously so a near-simultaneous re-trigger can't double-start.
        isSummarizing = true
        summarizingMeetingID = meeting.id
        summarizationStartedAt = Date()

        backgroundTask = Task { @MainActor in
            // Guarantees the busy flag clears on every exit path, including the
            // early "no source material" throw inside summarize().
            defer {
                self.isSummarizing = false
                self.summarizingMeetingID = nil
                self.summarizationStartedAt = nil
            }
            do {
                let parsed = try await self.summarize(meeting: meeting)
                meeting.summary = parsed.rawMarkdown

                let existing = Set(
                    meeting.todos.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
                for text in parsed.todoTexts {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !existing.contains(trimmed) else { continue }
                    do {
                        try ObsidianTodoSyncService.createMeetingTodo(
                            text: trimmed,
                            meeting: meeting,
                            in: modelContext
                        )
                    } catch {
                        // The summary itself succeeded; a failed to-do is a warning, not a failure.
                        Log.summarization.warning("Creating meeting to-do failed: \(error.localizedDescription)")
                        // Surfaced by MeetingPipelinePresentation (errorMessage ??
                        // warningMessage) in the ProcessingStatusCard error row,
                        // with a Dismiss affordance.
                        self.warningMessage = "Summary generated, but creating its to-dos failed: \(error.localizedDescription)"
                    }
                }
                do {
                    try modelContext.save()
                } catch {
                    Log.summarization.error("Saving summary failed: \(error.localizedDescription)")
                }
            } catch {
                // Cancellation (Swift's CancellationError or a wrapped URLSession
                // cancel) is not a real failure — never surface it.
                if Task.isCancelled { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func summarize(meeting: Meeting) async throws -> SummaryResponseParser.ParsedResponse {
        let rawTranscript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawTranscript.isEmpty || !freeformNotes.isEmpty else {
            throw SummarizationError.missingSourceMaterial
        }

        // Long meetings (this app's own transcripts run 50-80k+ characters) were
        // previously inlined whole into the prompt with no bound at all — tens of
        // thousands of input tokens sent to a local model every time. Bound it to
        // the same shared budget used for chat/terminology so it reliably fits
        // the model's context window alongside the rest of the prompt.
        let (transcript, transcriptWasTruncated) = LLMPromptSupport.truncated(
            rawTranscript,
            toFitTokenBudget: LLMPromptSupport.defaultTranscriptTokenBudget
        )

        let provider = LLMProviderFactory.current()
        isSummarizing = true
        errorMessage = nil
        warningMessage = nil
        providerDisplayName = provider.displayName
        phase = .sending
        defer {
            isSummarizing = false
            phase = .idle
        }

        let terminologyBlock = TerminologyService.renderTerminologyBlock(
            enabled: UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled),
            raw: UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )

        var prompt = Self.renderPrompt(
            template: UserDefaults.standard.string(forKey: AppPreferenceKey.summaryPromptTemplate) ?? Self.defaultPromptTemplate,
            meeting: meeting,
            transcript: transcript,
            freeformNotes: freeformNotes,
            terminologyBlock: terminologyBlock
        )

        // Reasoning models "think out loud" before answering, which on short
        // transcripts becomes pages of rambling that never reaches the summary.
        // When thinking is disabled (default), append the Qwen soft-switch and
        // allow only a tight output budget; when enabled, give room for the
        // reasoning to complete before the answer.
        let thinkingEnabled = LLMPromptSupport.thinkingEnabled()
        prompt = LLMPromptSupport.applyThinkingSwitch(to: prompt, thinkingEnabled: thinkingEnabled)
        // Thinking on → uncapped (user opted in); off → tight cap as the safety net.
        let tokenBudget = LLMPromptSupport.tokenBudget(thinkingEnabled: thinkingEnabled)

        var wasTruncated = false
        let retryPolicy = LLMRetryPolicy()
        let summary: String
        do {
            summary = try await retryPolicy.withRetry(
                onAttempt: { [weak self] attempt in
                    self?.phase = .retrying(attempt: attempt, maxAttempts: retryPolicy.maxAttempts)
                }
            ) {
                try await provider.generate(
                    prompt: prompt,
                    temperature: nil,
                    maxTokens: tokenBudget,
                    timeout: 120,
                    truncated: { wasTruncated = $0 }
                )
            }
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }

        var warnings: [String] = []
        if transcriptWasTruncated {
            warnings.append("The transcript was too long and was shortened (kept the start and end) to fit the model's context window.")
        }
        if wasTruncated {
            warnings.append("Summary may be truncated: \(provider.displayName) reached its output length limit.")
        }
        if !warnings.isEmpty {
            warningMessage = warnings.joined(separator: " ")
        }

        phase = .parsing
        // Strip any chain-of-thought the model still emitted (e.g. <think>…</think>).
        return SummaryResponseParser.parse(Self.stripReasoning(summary))
    }

    /// Cancels the detached background summarization task, if any. Called on app
    /// termination so the view-independent task doesn't outlive the process. The
    /// `Task.isCancelled` guard in `summarizeInBackground`'s catch suppresses the
    /// resulting cancellation error, so this is a clean stop.
    func cancelBackgroundWork() {
        backgroundTask?.cancel()
    }

    func clearError() {
        errorMessage = nil
    }

    func clearWarning() {
        warningMessage = nil
    }

    static func fetchAvailableModels(endpoint: String? = nil) async throws -> [String] {
        let provider = LLMProviderFactory.current()
        do {
            return try await provider.fetchAvailableModels(endpoint: endpoint ?? provider.endpoint)
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }
    }

    private static func mapProviderError(_ error: LLMProviderError) -> SummarizationError {
        switch error {
        case .invalidEndpoint(let provider):
            return .invalidEndpoint(provider: provider)
        case .requestFailed(_, _, let message):
            return .requestFailed(message)
        case .emptyResponse(let provider):
            return .emptyResponse(provider: provider)
        }
    }

    static func renderPrompt(
        template: String,
        meeting: Meeting,
        transcript: String,
        freeformNotes: String,
        terminologyBlock: String
    ) -> String {
        let formattedDate = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: meeting.date)
        }()

        return template
            .replacingOccurrences(of: "{{title}}", with: meeting.title)
            .replacingOccurrences(of: "{{scheduled_time}}", with: formattedDate)
            .replacingOccurrences(of: "{{participants}}", with: meeting.participants.isEmpty ? "Unknown" : meeting.participants.joined(separator: ", "))
            .replacingOccurrences(of: "{{transcript}}", with: transcript.isEmpty ? "None" : transcript)
            .replacingOccurrences(of: "{{freeform_notes}}", with: freeformNotes.isEmpty ? "None" : freeformNotes)
            .replacingOccurrences(of: "{{terminology_list}}", with: terminologyBlock)
    }
}
