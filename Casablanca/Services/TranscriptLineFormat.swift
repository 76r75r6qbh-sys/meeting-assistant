import Foundation

/// One parsed transcript line: `[label] <Speaker>: text`, speaker optional.
struct TranscriptLine: Equatable {
    /// The timestamp as written, e.g. `"12:34"` or `"1:02:03"`.
    var label: String
    var seconds: Double
    var speaker: String?
    var text: String
}

/// The plain-text transcript line format shared by rendering, parsing and
/// speaker renaming: one line per segment, `[mm:ss] <Speaker>: <text>` (or
/// `[h:mm:ss]`). The `<Speaker>: ` part is optional; old transcripts have none.
enum TranscriptLineFormat {

    /// Longest name accepted as a speaker prefix.
    static let maxSpeakerNameLength = 40

    /// `[label]` at line start, then an optional single space, then the rest.
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\[(\d{1,2}:\d{2}(?::\d{2})?)\] ?(.*)$"#
    )

    // MARK: - Parsing

    /// Parses a line without speaker knowledge. A `Name: ` prefix is ambiguous
    /// (`[00:10] Agenda: punt 1`), so `speaker` is always `nil` and the full
    /// text after the timestamp is returned. `nil` if there is no leading `[ts]`.
    static func parse(_ line: String) -> TranscriptLine? {
        parse(line, knownSpeakers: [])
    }

    /// Parses a line, treating a `Name: ` prefix as the speaker only when
    /// `Name` is in `knownSpeakers`. `nil` if there is no leading `[ts]`.
    static func parse(_ line: String, knownSpeakers: Set<String>) -> TranscriptLine? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = lineRegex.firstMatch(in: line, range: range),
              let labelRange = Range(match.range(at: 1), in: line),
              let restRange = Range(match.range(at: 2), in: line)
        else { return nil }

        let label = String(line[labelRange])
        guard let seconds = seconds(fromLabel: label) else { return nil }
        let rest = String(line[restRange])

        if let (name, text) = splitSpeakerPrefix(rest), knownSpeakers.contains(name) {
            return TranscriptLine(label: label, seconds: seconds, speaker: name, text: text)
        }
        return TranscriptLine(label: label, seconds: seconds, speaker: nil, text: rest)
    }

    /// Seconds for a `mm:ss` or `h:mm:ss` label; `nil` if it is neither.
    static func seconds(fromLabel label: String) -> Double? {
        let parts = label.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) })
        else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        let total = values.reduce(0) { $0 * 60 + $1 }
        return Double(total)
    }

    // MARK: - Formatting

    /// `mm:ss` below one hour, `h:mm:ss` from one hour on. Fractions are
    /// truncated. Byte-identical to the formatter TranscriptionService used.
    static func timestampLabel(seconds: Double) -> String {
        let totalSeconds = seconds.isFinite ? Int(seconds) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// One line per segment, `[label] Name: text`. A `nil` or unknown
    /// `speakerID` (or an empty display name) gets no prefix.
    static func render(_ segments: [SpeakerSegment], speakers: [SpeakerInfo]) -> String {
        var names: [String: String] = [:]
        for speaker in speakers where names[speaker.id] == nil {
            names[speaker.id] = speaker.displayName
        }
        return segments.map { segment in
            let label = "[\(timestampLabel(seconds: segment.start))]"
            if let id = segment.speakerID, let name = names[id], !name.isEmpty {
                return "\(label) \(name): \(segment.text)"
            }
            return "\(label) \(segment.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Renaming

    /// Rewrites the `old: ` speaker prefix to `new: ` on every line that starts
    /// with `[ts] old: `. Text elsewhere on the line (including another
    /// `old: `), lines without a timestamp and all other bytes are untouched,
    /// so hand edits and terminology fixes survive.
    static func renameSpeaker(in transcript: String, from old: String, to new: String) -> String {
        guard !old.isEmpty, old != new else { return transcript }
        let oldPrefix = "\(old): "
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line -> String in
            let line = String(line)
            guard let close = timestampPrefixEnd(line) else { return line }
            let afterTimestamp = line[close...]
            guard afterTimestamp.hasPrefix(" " + oldPrefix) else { return line }
            let textStart = afterTimestamp.index(afterTimestamp.startIndex, offsetBy: 1 + oldPrefix.count)
            return String(line[..<close]) + " \(new): " + afterTimestamp[textStart...]
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Splits `Name: text` per the prefix grammar: 1–40 characters without
    /// `:` or `[`, then `": "`.
    private static func splitSpeakerPrefix(_ rest: String) -> (String, String)? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon]
        guard !name.isEmpty, name.count <= maxSpeakerNameLength, !name.contains("["),
              rest[rest.index(after: colon)...].hasPrefix(" ")
        else { return nil }
        let textStart = rest.index(colon, offsetBy: 2)
        return (String(name), String(rest[textStart...]))
    }

    /// Index just past the closing `]` of a valid leading `[label]`, if any.
    private static func timestampPrefixEnd(_ line: String) -> String.Index? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let label = line[line.index(after: line.startIndex)..<close]
        guard seconds(fromLabel: String(label)) != nil else { return nil }
        return line.index(after: close)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
