import Foundation

/// Pure presentation logic that turns a raw transcript string into timestamped
/// chapters for readable rendering. The transcript format produced by
/// `TranscriptionResult.formattedTranscript` is one segment per line:
///
///     [mm:ss] some spoken text
///     [h:mm:ss] more text   (hours appear once the recording passes 1h)
///
/// Segments are grouped into fixed ~5-minute chapters by their start time. A
/// transcript with NO parseable timestamps yields a single fallback chapter
/// holding the original text, so callers can render it plainly.
enum TranscriptPresentation {
    /// One timestamped line of the transcript.
    struct Segment: Equatable, Identifiable {
        let id = UUID()
        let start: TimeInterval
        let text: String

        static func == (lhs: Segment, rhs: Segment) -> Bool {
            lhs.start == rhs.start && lhs.text == rhs.text
        }
    }

    /// A group of segments spanning one chapter window.
    struct Chapter: Equatable, Identifiable {
        let id = UUID()
        /// Inclusive lower bound of the chapter window, in seconds.
        let startSeconds: TimeInterval
        /// Exclusive upper bound of the chapter window, in seconds.
        let endSeconds: TimeInterval
        let segments: [Segment]

        static func == (lhs: Chapter, rhs: Chapter) -> Bool {
            lhs.startSeconds == rhs.startSeconds
                && lhs.endSeconds == rhs.endSeconds
                && lhs.segments == rhs.segments
        }

        /// "00:00 – 05:00" style title for the chapter window.
        var title: String {
            "\(TranscriptPresentation.formatClock(startSeconds)) – \(TranscriptPresentation.formatClock(endSeconds))"
        }
    }

    /// The result of parsing a transcript.
    enum Parsed: Equatable {
        /// Timestamped transcript grouped into chapters.
        case chapters([Chapter])
        /// No parseable timestamps; render `text` plainly.
        case plain(String)
        /// Empty / whitespace-only transcript.
        case empty
    }

    static let chapterLength: TimeInterval = 300  // 5 minutes

    /// Parses a raw transcript into chapters (timestamped) or a plain fallback.
    static func parse(_ transcript: String, chapterLength: TimeInterval = chapterLength) -> Parsed {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let segments = parseSegments(transcript)
        guard !segments.isEmpty else { return .plain(trimmed) }

        let chapters = groupIntoChapters(segments, chapterLength: chapterLength)
        return .chapters(chapters)
    }

    /// Parses each `[time] text` line into a `Segment`. Lines without a leading
    /// timestamp are ignored (they're not part of the timestamped format).
    static func parseSegments(_ transcript: String) -> [Segment] {
        var segments: [Segment] = []
        for rawLine in transcript.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["),
                  let close = line.firstIndex(of: "]") else { continue }

            let stampString = String(line[line.index(after: line.startIndex)..<close])
            guard let seconds = parseTimestamp(stampString) else { continue }

            let textStart = line.index(after: close)
            let text = String(line[textStart...]).trimmingCharacters(in: .whitespaces)
            segments.append(Segment(start: seconds, text: text))
        }
        return segments
    }

    /// Parses "mm:ss" or "h:mm:ss" into seconds. Returns nil if malformed.
    static func parseTimestamp(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":").map(String.init)
        guard parts.allSatisfy({ Int($0) != nil }) else { return nil }
        switch parts.count {
        case 2:
            guard let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
            return TimeInterval(m * 60 + s)
        case 3:
            guard let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return nil }
            return TimeInterval(h * 3600 + m * 60 + s)
        default:
            return nil
        }
    }

    private static func groupIntoChapters(_ segments: [Segment], chapterLength: TimeInterval) -> [Chapter] {
        guard chapterLength > 0 else {
            return [Chapter(startSeconds: 0, endSeconds: 0, segments: segments)]
        }
        // Group by chapter index (start / length), preserving order.
        var buckets: [Int: [Segment]] = [:]
        var order: [Int] = []
        for segment in segments {
            let index = Int(segment.start / chapterLength)
            if buckets[index] == nil { order.append(index) }
            buckets[index, default: []].append(segment)
        }
        return order.sorted().map { index in
            let start = TimeInterval(index) * chapterLength
            return Chapter(
                startSeconds: start,
                endSeconds: start + chapterLength,
                segments: buckets[index] ?? []
            )
        }
    }

    /// Formats seconds as "mm:ss", or "h:mm:ss" once past an hour.
    static func formatClock(_ time: TimeInterval) -> String {
        let total = Int(time)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
