import Foundation
import Observation

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

    Timestamped notes (optional history):
    {{timestamped_notes}}
    """

    private(set) var isSummarizing = false
    private(set) var statusMessage = ""
    var errorMessage: String?
    var warningMessage: String?

    func summarize(meeting: Meeting) async throws -> SummaryResponseParser.ParsedResponse {
        let transcript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestampedNotes = meeting.timestampedNotes
            .map { "\($0.formattedTimestamp) \($0.text)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty || !freeformNotes.isEmpty || !timestampedNotes.isEmpty else {
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

        let prompt = Self.renderPrompt(
            template: UserDefaults.standard.string(forKey: AppPreferenceKey.summaryPromptTemplate) ?? Self.defaultPromptTemplate,
            meeting: meeting,
            transcript: transcript,
            timestampedNotes: timestampedNotes,
            freeformNotes: freeformNotes,
            terminologyBlock: terminologyBlock
        )

        var wasTruncated = false
        let summary: String
        do {
            summary = try await provider.generate(
                prompt: prompt,
                temperature: nil,
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
        return SummaryResponseParser.parse(summary)
    }

    func clearError() {
        errorMessage = nil
    }

    func clearWarning() {
        warningMessage = nil
    }

    static func fetchAvailableModels(endpoint: String? = nil) async throws -> [String] {
        let provider = LLMProviderFactory.current()
        let endpointToUse = endpoint ?? Self.currentEndpoint(for: provider)
        do {
            return try await provider.fetchAvailableModels(endpoint: endpointToUse)
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }
    }

    private static func currentEndpoint(for provider: LLMProvider) -> String {
        if provider is OMLXProvider {
            return UserDefaults.standard.string(forKey: AppPreferenceKey.omlxEndpoint) ?? "http://localhost:8000/v1"
        }
        return UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434"
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
        timestampedNotes: String,
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
            .replacingOccurrences(of: "{{timestamped_notes}}", with: timestampedNotes.isEmpty ? "None" : timestampedNotes)
            .replacingOccurrences(of: "{{freeform_notes}}", with: freeformNotes.isEmpty ? "None" : freeformNotes)
            .replacingOccurrences(of: "{{terminology_list}}", with: terminologyBlock)
    }
}
