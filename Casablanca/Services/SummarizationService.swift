import Foundation
import Observation

enum SummarizationError: LocalizedError {
    case invalidEndpoint
    case missingSourceMaterial
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Ollama endpoint is invalid. Update it in Settings."
        case .missingSourceMaterial:
            return "Casablanca needs a transcript or notes before it can summarize the meeting."
        case .requestFailed(let message):
            return message
        case .emptyResponse:
            return "Ollama returned an empty summary."
        }
    }
}

@MainActor
@Observable
final class SummarizationService {
    struct OllamaModel: Decodable, Identifiable {
        let name: String

        var id: String { name }
    }

    private struct OllamaTagsResponse: Decodable {
        let models: [OllamaModel]
    }

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

    Meeting title: {{title}}
    Scheduled time: {{scheduled_time}}

    Transcript:
    {{transcript}}

    Timestamped notes:
    {{timestamped_notes}}

    Freeform notes:
    {{freeform_notes}}
    """

    private struct OllamaGenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
    }

    private struct OllamaGenerateResponse: Decodable {
        let response: String?
        let error: String?
    }

    private(set) var isSummarizing = false
    private(set) var statusMessage = ""
    var errorMessage: String?

    func summarize(meeting: Meeting) async throws -> String {
        let transcript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestampedNotes = meeting.timestampedNotes
            .map { "\($0.formattedTimestamp) \($0.text)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty || !freeformNotes.isEmpty || !timestampedNotes.isEmpty else {
            throw SummarizationError.missingSourceMaterial
        }

        guard let url = makeGenerateURL() else {
            throw SummarizationError.invalidEndpoint
        }

        isSummarizing = true
        errorMessage = nil
        statusMessage = "Sending transcript and notes to Ollama..."
        defer { isSummarizing = false }

        let prompt = Self.renderPrompt(
            template: UserDefaults.standard.string(forKey: AppPreferenceKey.summaryPromptTemplate) ?? Self.defaultPromptTemplate,
            meeting: meeting,
            transcript: transcript,
            timestampedNotes: timestampedNotes,
            freeformNotes: freeformNotes
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            OllamaGenerateRequest(
                model: UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaModel) ?? "llama3.2",
                prompt: prompt,
                stream: false
            )
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SummarizationError.requestFailed("Could not reach Ollama: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.requestFailed("Ollama returned an invalid response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SummarizationError.requestFailed(
                body.isEmpty
                    ? "Ollama request failed with status \(httpResponse.statusCode)."
                    : "Ollama request failed: \(body)"
            )
        }

        let payload = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        if let error = payload.error, !error.isEmpty {
            throw SummarizationError.requestFailed("Ollama returned an error: \(error)")
        }

        let summary = payload.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else {
            throw SummarizationError.emptyResponse
        }

        statusMessage = "Summary generated"
        return summary
    }

    func clearError() {
        errorMessage = nil
    }

    static func fetchAvailableModels(endpoint: String? = nil) async throws -> [String] {
        guard let url = makeURL(
            endpoint: endpoint ?? UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434",
            path: "tags"
        ) else {
            throw SummarizationError.invalidEndpoint
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw SummarizationError.requestFailed("Could not reach Ollama: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.requestFailed("Ollama returned an invalid response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SummarizationError.requestFailed(
                body.isEmpty
                    ? "Ollama model lookup failed with status \(httpResponse.statusCode)."
                    : "Ollama model lookup failed: \(body)"
            )
        }

        let payload = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return payload.models
            .map(\.name)
            .sorted()
    }

    private func makeGenerateURL() -> URL? {
        Self.makeURL(
            endpoint: UserDefaults.standard.string(forKey: AppPreferenceKey.ollamaEndpoint) ?? "http://localhost:11434",
            path: "generate"
        )
    }

    private static func makeURL(endpoint: String, path: String) -> URL? {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty else {
            return nil
        }

        if trimmedEndpoint.hasSuffix("/api/\(path)") {
            return URL(string: trimmedEndpoint)
        }

        if trimmedEndpoint.hasSuffix("/api") {
            return URL(string: "\(trimmedEndpoint)/\(path)")
        }

        if trimmedEndpoint.hasSuffix("/") {
            return URL(string: "\(trimmedEndpoint)api/\(path)")
        }

        return URL(string: "\(trimmedEndpoint)/api/\(path)")
    }

    private static func renderPrompt(
        template: String,
        meeting: Meeting,
        transcript: String,
        timestampedNotes: String,
        freeformNotes: String
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
    }
}
