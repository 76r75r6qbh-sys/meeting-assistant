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

    // MARK: - Speaker names

    /// A display name that is safe as a line prefix and parses back: trimmed,
    /// `:` `[` `]` replaced by a space, whitespace runs collapsed to one space,
    /// cut to ``maxSpeakerNameLength`` characters (then trimmed again).
    /// `""` when nothing is left; callers treat that as "no name".
    static func sanitizedSpeakerName(_ raw: String) -> String {
        let replaced = String(raw.map { ":[]".contains($0) ? " " : $0 })
        let collapsed = replaced
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(maxSpeakerNameLength))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Parsing

    /// Parses a line without speaker knowledge. A `Name: ` prefix is ambiguous
    /// (`[00:10] Agenda: punt 1`), so `speaker` is always `nil` and the full
    /// text after the timestamp is returned. `nil` if there is no leading `[ts]`.
    static func parse(_ line: String) -> TranscriptLine? {
        parse(line, knownSpeakers: [])
    }

    /// Parses a line, treating a `Name: ` prefix as the speaker only when
    /// `Name` is in `knownSpeakers`. `nil` if there is no leading `[ts]`.
    ///
    /// The single space after `]` is optional: `[00:10]text` parses as label
    /// `00:10`, text `text` (and `[00:10]Youri: ja` still yields speaker
    /// `Youri`). `[00:10] Youri:` and `[00:10] Youri: ` yield empty text.
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
    /// Grammar: the first component has 1–2 digits, every later one exactly 2
    /// (`5:07`, `12:34`, `1:02:03`, `10:02:03`), so the sum can never overflow.
    /// `strict` also requires the minutes and seconds to be < 60 (in `mm:ss`
    /// the first field is minutes; hours are unbounded), for labels a model
    /// cites (`99:99`, `1:60:00`); the default accepts them, as it always did.
    static func seconds(fromLabel label: String, strict: Bool = false) -> Double? {
        let parts = label.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              (1...2).contains(parts[0].count),
              parts.dropFirst().allSatisfy({ $0.count == 2 })
        else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        if strict {
            let bounded = values.count == 2 ? values[...] : values.dropFirst()
            guard bounded.allSatisfy({ $0 < 60 }) else { return nil }
        }
        let total = values.reduce(0) { $0 * 60 + $1 }
        return Double(total)
    }

    // MARK: - Formatting

    /// `mm:ss` below one hour, `h:mm:ss` from one hour on. Fractions are
    /// truncated. Byte-identical to the formatter TranscriptionService used
    /// for every value it could format; non-finite input counts as 0 and
    /// values beyond `Int`'s range are clamped instead of trapping.
    static func timestampLabel(seconds: Double) -> String {
        let finite = seconds.isFinite ? seconds : 0
        // Double(Int.max) rounds up to 2^63, which Int() cannot hold.
        let clamped = min(max(finite, Double(Int.min)), Double(Int.max).nextDown)
        let totalSeconds = Int(clamped)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            // `\(hours)` rather than `%d`: `%d` is 32-bit and would garble large Ints.
            return "\(hours)" + String(format: ":%02d:%02d", minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// One line per segment, `[label] Name: text`, with `Name` passed through
    /// ``sanitizedSpeakerName(_:)``. A `nil` or unknown `speakerID` (or a
    /// display name that sanitizes to empty) gets no prefix.
    static func render(_ segments: [SpeakerSegment], speakers: [SpeakerInfo]) -> String {
        var names: [String: String] = [:]
        for speaker in speakers where names[speaker.id] == nil {
            names[speaker.id] = sanitizedSpeakerName(speaker.displayName)
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

    /// Rewrites the `old` speaker prefix to `new` on every line that starts
    /// with `[ts] old: ` (or is exactly `[ts] old:`, i.e. empty text). The
    /// space after `]` is optional, as in `parse`, and kept as found. Text
    /// elsewhere on the line (including another `old: `), lines without a
    /// valid timestamp and all other bytes, line endings (`\n` and `\r\n`)
    /// included, are untouched, so hand edits and terminology fixes survive.
    /// `new` is passed through ``sanitizedSpeakerName(_:)``; when that is empty
    /// the transcript is returned unchanged. `old` is matched as written.
    static func renameSpeaker(in transcript: String, from old: String, to rawNew: String) -> String {
        let new = sanitizedSpeakerName(rawNew)
        guard !old.isEmpty, !new.isEmpty, old != new else { return transcript }
        // Split on the scalar: Swift treats "\r\n" as one Character, so a
        // Character split on "\n" would leave CRLF transcripts as one line.
        let lines = transcript.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { scalars -> String in
            var body = String(String.UnicodeScalarView(scalars))
            var ending = ""
            if body.unicodeScalars.last == "\r" {
                body.unicodeScalars.removeLast()
                ending = "\r"
            }
            return renameSpeakerInLine(body, from: old, to: new) + ending
        }.joined(separator: "\n")
    }

    /// `renameSpeaker` for one line without its line terminator.
    private static func renameSpeakerInLine(_ line: String, from old: String, to new: String) -> String {
        guard let close = timestampPrefixEnd(line) else { return line }
        let afterTimestamp = line[close...]
        let spacing = afterTimestamp.hasPrefix(" ") ? " " : ""
        let rest = afterTimestamp.dropFirst(spacing.count)
        let head = String(line[..<close]) + spacing
        if rest == "\(old):" {
            return head + "\(new):"
        }
        guard rest.hasPrefix("\(old): ") else { return line }
        return head + "\(new): " + rest.dropFirst(old.count + 2)
    }

    // MARK: - Helpers

    /// Splits `Name: text` per the prefix grammar: 1–40 characters without
    /// `:` or `[`, then `": "`. A name with a colon at the very end of the line
    /// (`Name:`) or followed by just a space (`Name: `) has empty text.
    private static func splitSpeakerPrefix(_ rest: String) -> (String, String)? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon]
        guard !name.isEmpty, name.count <= maxSpeakerNameLength, !name.contains("[") else { return nil }
        let afterColon = rest[rest.index(after: colon)...]
        if afterColon.isEmpty { return (String(name), "") }
        guard afterColon.hasPrefix(" ") else { return nil }
        return (String(name), String(afterColon.dropFirst()))
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
