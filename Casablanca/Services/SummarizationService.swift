import Foundation
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
    You are a meeting assistant creating concise, high-signal meeting notes.

    Use only the information provided below. If something is unclear or missing, say so briefly instead of guessing.

    Return markdown with these sections:
    # Summary
    ## Decisions
    ## Action Items
    ## Risks and Blockers
    ## Follow-ups

    Keep action items concrete and include owners when they are stated.
    Each action item MUST be a `- ` bullet under "## Action Items". If there are no action items, write "## Action Items" with nothing below it.

    {{terminology_list}}

    Meeting title: {{title}}
    Scheduled time: {{scheduled_time}}

    Transcript:
    {{transcript}}

    Freeform notes:
    {{freeform_notes}}
    """

    /// Upper bound on generated summary length when thinking is OFF. Local models
    /// can otherwise ramble or loop for thousands of tokens on a short transcript.
    static let maxSummaryTokens = 2000

    /// Larger budget when the user enables model thinking, so the reasoning has
    /// room to finish before the actual answer (still bounded to avoid runaways).
    static let maxThinkingTokens = 8000

    /// Removes chain-of-thought blocks reasoning models emit before their answer
    /// (e.g. `<think>…</think>` / `<thinking>…</thinking>`), so they don't end up
    /// in the stored summary. Handles an unclosed tag (output cut mid-thought) by
    /// dropping from the opening tag onward.
    static func stripReasoning(_ text: String) -> String {
        var s = text
        for tag in ["think", "thinking"] {
            s = s.replacingOccurrences(
                of: "(?is)<\(tag)>.*?</\(tag)>",
                with: "",
                options: .regularExpression
            )
            if let open = s.range(of: "<\(tag)>", options: .caseInsensitive) {
                s = String(s[..<open.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private(set) var isSummarizing = false
    private(set) var statusMessage = ""
    var errorMessage: String?
    var warningMessage: String?

    /// The meeting currently being summarized in the background (nil when idle).
    /// Lets list rows show a spinner on the specific meeting being processed.
    private(set) var summarizingMeetingID: UUID?

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

        backgroundTask = Task { @MainActor in
            // Guarantees the busy flag clears on every exit path, including the
            // early "no source material" throw inside summarize().
            defer {
                self.isSummarizing = false
                self.summarizingMeetingID = nil
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
                    try? ObsidianTodoSyncService.createMeetingTodo(
                        text: trimmed,
                        meeting: meeting,
                        in: modelContext
                    )
                }
                try? modelContext.save()
            } catch {
                // Cancellation (Swift's CancellationError or a wrapped URLSession
                // cancel) is not a real failure — never surface it.
                if Task.isCancelled { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func summarize(meeting: Meeting) async throws -> SummaryResponseParser.ParsedResponse {
        let transcript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty || !freeformNotes.isEmpty else {
            throw SummarizationError.missingSourceMaterial
        }

        let provider = LLMProviderFactory.current()
        isSummarizing = true
        errorMessage = nil
        warningMessage = nil
        statusMessage = "Sending transcript and notes to \(provider.displayName)..."
        defer { isSummarizing = false }

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
        let thinkingEnabled = UserDefaults.standard.bool(forKey: AppPreferenceKey.summaryThinkingEnabled)
        if !thinkingEnabled {
            prompt += "\n\n/no_think"
        }
        let tokenBudget = thinkingEnabled ? Self.maxThinkingTokens : Self.maxSummaryTokens

        var wasTruncated = false
        let summary: String
        do {
            summary = try await provider.generate(
                prompt: prompt,
                temperature: nil,
                maxTokens: tokenBudget,
                timeout: 120,
                truncated: { wasTruncated = $0 }
            )
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }

        if wasTruncated {
            warningMessage = "Summary may be truncated: \(provider.displayName) reached its output length limit."
        }

        statusMessage = "Summary generated"
        // Strip any chain-of-thought the model still emitted (e.g. <think>…</think>).
        return SummaryResponseParser.parse(Self.stripReasoning(summary))
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
        case .requestFailed(_, let message):
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
            .replacingOccurrences(of: "{{transcript}}", with: transcript.isEmpty ? "None" : transcript)
            .replacingOccurrences(of: "{{freeform_notes}}", with: freeformNotes.isEmpty ? "None" : freeformNotes)
            .replacingOccurrences(of: "{{terminology_list}}", with: terminologyBlock)
    }
}
