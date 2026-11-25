import Foundation

/// The clean-up Whisper's text gets before it becomes a transcript line:
/// control tokens (`<|en|>`, `<|0.00|>`, …) out, whitespace runs collapsed,
/// no space before `, . ; : ! ?`, trimmed. Shared by segment text
/// (TranscriptionService) and text rebuilt from words (SpeakerAttribution).
enum WhisperTextCleaner {
    private static let controlTokenRegex = try! NSRegularExpression(pattern: #"<\|[^|>]+?\|>"#)
    /// Hoisted: `clean` runs once per segment (thousands of times for a long
    /// meeting) and `replacingOccurrences(options: .regularExpression)`
    /// recompiles the pattern on every call.
    private static let repeatedWhitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
    private static let whitespaceBeforePunctuationRegex = try! NSRegularExpression(pattern: #"\s+([,.;:!?])"#)

    /// Only the control tokens out, nothing else touched — for a single word,
    /// whose leading space is its word boundary and must survive.
    static func removingControlTokens(_ text: String) -> String {
        controlTokenRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    static func clean(_ text: String) -> String {
        let withoutControlTokens = controlTokenRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
        let collapsedWhitespace = repeatedWhitespaceRegex.stringByReplacingMatches(
            in: withoutControlTokens,
            options: [],
            range: NSRange(withoutControlTokens.startIndex..., in: withoutControlTokens),
            withTemplate: " "
        )
        let withoutExtraWhitespace = whitespaceBeforePunctuationRegex.stringByReplacingMatches(
            in: collapsedWhitespace,
            options: [],
            range: NSRange(collapsedWhitespace.startIndex..., in: collapsedWhitespace),
            withTemplate: "$1"
        )
        return withoutExtraWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
