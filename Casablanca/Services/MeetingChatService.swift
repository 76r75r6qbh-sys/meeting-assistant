import Foundation
import Observation

/// One turn in an "Ask your meeting" conversation. In-memory only (no
/// persistence in v1).
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Grounded, single-meeting Q&A backed by the local LLM. The conversation lives
/// only in memory and is scoped to one meeting at a time: switching meetings
/// (a different `currentMeetingID`) clears the history.
///
/// The `LLMProvider` protocol is SINGLE-TURN (one prompt string), so this
/// service flattens the system framing + meeting context + prior Q&A turns +
/// the new question into one prompt via `MeetingChatService.assemblePrompt`,
/// rather than extending the protocol. It reuses `LLMProviderFactory.current()`,
/// `LLMRetryPolicy`, and the shared `LLMPromptSupport` thinking/strip helpers.
@MainActor
@Observable
final class MeetingChatService {
    /// chars-per-token heuristic. No real tokenizer exists in the app; 4 chars ≈
    /// 1 token is the standard rough estimate for English text and is good
    /// enough to keep the prompt inside the model's context window.
    static let charsPerToken = 4

    /// Default token budget for the WHOLE assembled prompt. Conservative so it
    /// fits comfortably alongside the model's output budget within a typical
    /// local context window (e.g. 8k). Truncation trims the transcript to fit.
    static let defaultPromptTokenBudget = 6000

    /// System framing that constrains the model to the provided material.
    static let systemFraming = """
    You are a helpful assistant answering questions about a single meeting.
    Answer ONLY using the meeting content provided below (its summary, the \
    user's notes, and the transcript). If the answer is not contained in that \
    content, say you don't know based on the meeting — do not guess or use \
    outside knowledge. Keep answers concise and specific, and quote or \
    reference the meeting where helpful.
    """

    private(set) var messages: [ChatMessage] = []
    private(set) var isAnswering = false
    var errorMessage: String?

    /// The meeting the current conversation belongs to. When `ask` is called for
    /// a different meeting, the history resets.
    private(set) var currentMeetingID: UUID?

    private var task: Task<Void, Never>?

    /// Switch the active meeting, clearing the conversation if it changed. Safe
    /// to call repeatedly with the same id (no-op).
    func activate(meetingID: UUID) {
        guard currentMeetingID != meetingID else { return }
        cancel()
        messages = []
        errorMessage = nil
        currentMeetingID = meetingID
    }

    /// Ask a grounded question about `meeting`. Appends the user turn and an
    /// assistant turn (filled in on completion). Batch (no streaming).
    func ask(_ question: String, meeting: Meeting) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        activate(meetingID: meeting.id)

        // Snapshot history (the prior turns) BEFORE appending the new question,
        // so the prompt's "previous Q&A" section excludes the in-flight turn.
        let priorTurns = messages

        messages.append(ChatMessage(role: .user, text: trimmed))
        errorMessage = nil
        isAnswering = true

        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let thinkingEnabled = LLMPromptSupport.thinkingEnabled()
        let basePrompt = Self.assemblePrompt(
            summary: summary,
            notes: notes,
            transcript: transcript,
            history: priorTurns,
            question: trimmed,
            tokenBudget: Self.defaultPromptTokenBudget
        )
        let prompt = LLMPromptSupport.applyThinkingSwitch(to: basePrompt, thinkingEnabled: thinkingEnabled)

        let provider = LLMProviderFactory.current()
        let retryPolicy = LLMRetryPolicy()

        task = Task { @MainActor in
            defer { self.isAnswering = false }
            do {
                let raw = try await retryPolicy.withRetry {
                    try await provider.generate(
                        prompt: prompt,
                        temperature: nil,
                        maxTokens: LLMPromptSupport.tokenBudget(thinkingEnabled: thinkingEnabled),
                        timeout: 120,
                        truncated: nil
                    )
                }
                if Task.isCancelled { return }
                let answer = LLMPromptSupport.stripReasoning(raw)
                self.messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: answer.isEmpty ? "\(provider.displayName) returned an empty answer." : answer
                    )
                )
            } catch {
                if Task.isCancelled { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Cancels the in-flight answer, if any. The `Task.isCancelled` guards stop
    /// the cancelled request from appending a stale turn or surfacing an error.
    func cancel() {
        task?.cancel()
        task = nil
        isAnswering = false
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Prompt assembly (pure, testable)

    /// Flattens the grounded chat into a single prompt string and enforces a
    /// `tokenBudget` (chars ≈ tokens × `charsPerToken`). The framing, summary,
    /// notes, prior Q&A turns and the new question are ALWAYS kept intact; when
    /// the assembled prompt would exceed the budget, only the TRANSCRIPT is
    /// truncated (middle-elided — head and tail carry the most context). If the
    /// fixed parts alone already exceed the budget the transcript is dropped
    /// entirely (its section header still appears, marked omitted).
    ///
    /// Pure and side-effect-free so the truncation logic is unit-testable.
    static func assemblePrompt(
        summary: String,
        notes: String,
        transcript: String,
        history: [ChatMessage],
        question: String,
        tokenBudget: Int
    ) -> String {
        let budgetChars = max(0, tokenBudget) * charsPerToken

        let summaryBlock = summary.isEmpty ? "" : "## Meeting summary\n\(summary)\n\n"
        let notesBlock = notes.isEmpty ? "" : "## User notes\n\(notes)\n\n"
        let historyBlock = renderHistory(history)
        let questionBlock = "## Question\n\(question)"

        // Everything that is never truncated.
        let fixedPrefix = systemFraming + "\n\n" + summaryBlock + notesBlock
        let fixedSuffix = "\n\n" + historyBlock + questionBlock
        let fixedChars = fixedPrefix.count + fixedSuffix.count
        // Account for the transcript section header we add around the body.
        let transcriptHeader = "## Transcript\n"
        let omittedMarker = "## Transcript\n[Transcript omitted — too long to include.]"

        guard !transcript.isEmpty else {
            return fixedPrefix + fixedSuffix
        }

        // How many chars remain for the transcript body after the fixed parts
        // and the transcript header.
        let available = budgetChars - fixedChars - transcriptHeader.count

        if transcript.count <= available {
            // Under budget — include the full transcript.
            return fixedPrefix + transcriptHeader + transcript + fixedSuffix
        }

        guard available > 0 else {
            // No room for any transcript — drop it but keep a marker so the
            // model knows content was withheld.
            return fixedPrefix + omittedMarker + fixedSuffix
        }

        let trimmed = middleElide(transcript, toCharBudget: available)
        return fixedPrefix + transcriptHeader + trimmed + fixedSuffix
    }

    /// Renders prior Q&A turns into a compact transcript-style block. Empty
    /// history yields an empty string (no stray header).
    static func renderHistory(_ history: [ChatMessage]) -> String {
        guard !history.isEmpty else { return "" }
        let lines = history.map { msg -> String in
            let speaker = msg.role == .user ? "User" : "Assistant"
            return "\(speaker): \(msg.text)"
        }
        return "## Previous Q&A\n" + lines.joined(separator: "\n") + "\n\n"
    }

    /// Keeps the head and tail of `text`, eliding the middle with a marker, so
    /// the result fits within `budget` characters. The opening and closing of a
    /// transcript usually carry the most context (agenda + wrap-up), so a middle
    /// elision preserves more signal than a tail cut.
    static func middleElide(_ text: String, toCharBudget budget: Int) -> String {
        guard text.count > budget else { return text }
        let marker = "\n\n[… transcript truncated to fit context window …]\n\n"
        guard budget > marker.count else {
            // Not even room for the marker — return a hard prefix.
            return String(text.prefix(max(0, budget)))
        }
        let keep = budget - marker.count
        let headLen = keep / 2
        let tailLen = keep - headLen
        let head = text.prefix(headLen)
        let tail = text.suffix(tailLen)
        return head + marker + tail
    }
}
