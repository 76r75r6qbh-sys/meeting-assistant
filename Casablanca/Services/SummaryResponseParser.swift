// Casablanca/Services/SummaryResponseParser.swift
import Foundation

enum SummaryResponseParser {
    struct ParsedResponse {
        let summary: String
        let todoTexts: [String]
    }

    static func parse(_ response: String) -> ParsedResponse {
        let actionItemsMarker = "\n## Action Items"

        guard let markerRange = response.range(of: actionItemsMarker) else {
            return ParsedResponse(
                summary: response.trimmingCharacters(in: .whitespacesAndNewlines),
                todoTexts: []
            )
        }

        let summary = String(response[response.startIndex..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let afterMarker = String(response[markerRange.upperBound...])

        // Action items end at the next ## section header or end of string
        let actionSection: String
        let searchStart = afterMarker.index(afterMarker.startIndex, offsetBy: min(1, afterMarker.count))
        if searchStart < afterMarker.endIndex,
           let nextSectionRange = afterMarker.range(of: "\n## ", range: searchStart..<afterMarker.endIndex) {
            actionSection = String(afterMarker[afterMarker.startIndex..<nextSectionRange.lowerBound])
        } else {
            actionSection = afterMarker
        }

        let todoTexts = actionSection
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return nil }
                let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }

        return ParsedResponse(summary: summary, todoTexts: todoTexts)
    }
}
