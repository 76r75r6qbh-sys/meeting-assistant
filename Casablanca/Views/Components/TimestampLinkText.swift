import Foundation
import SwiftUI

/// `[mm:ss]` / `[h:mm:ss]` labels in summaries, to-dos and transcript lines
/// as links that jump to that moment of a meeting (point 8).
///
/// Links use the in-app `casablanca-timestamp://jump/<meetingID>?t=<seconds>`
/// scheme, which is never registered with the system: the window handles it
/// through `handlesTimestampLinks()` (an `OpenURLAction`) and hands the jump
/// to `MeetingDetailNavigator`.
enum TimestampLinks {
    static let urlScheme = "casablanca-timestamp"
    private static let urlHost = "jump"
    private static let secondsQueryName = "t"

    /// `[label]` with the transcript line grammar's shape: first component
    /// 1–2 ASCII digits, then one or two components of exactly 2 digits.
    /// `TranscriptLineFormat.seconds(fromLabel:)` has the final word.
    private static let labelPattern = try! NSRegularExpression(
        pattern: #"\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\]"#
    )

    // MARK: - Finding labels

    /// Every `[mm:ss]` / `[h:mm:ss]` label in `text` (range includes the
    /// brackets) with its seconds, in order. Labels inside inline code spans
    /// (a run of n backticks closed by a run of exactly n on the same line)
    /// and fenced code blocks (``` or ~~~, indented at most 3 spaces, closed
    /// by the same character at least as long, or running to the end) are
    /// skipped. Seconds come from `TranscriptLineFormat.seconds(fromLabel:)`,
    /// so a label links exactly when the transcript format would parse it.
    static func ranges(in text: String) -> [(range: Range<String.Index>, seconds: Double)] {
        guard text.contains("[") else { return [] }
        let code = codeRanges(in: text)
        let matches = labelPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result: [(range: Range<String.Index>, seconds: Double)] = []
        for match in matches {
            guard let whole = Range(match.range, in: text),
                  let labelRange = Range(match.range(at: 1), in: text),
                  let seconds = TranscriptLineFormat.seconds(fromLabel: String(text[labelRange])),
                  !code.contains(where: { $0.overlaps(whole) })
            else { continue }
            result.append((whole, seconds))
        }
        return result
    }

    /// Ranges of fenced code blocks (fence lines included) and inline code
    /// spans (backticks included).
    static func codeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var openFence: (character: Character, length: Int, start: String.Index)?
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex

            if let fence = openFence {
                if let closing = fenceMarker(line), closing.character == fence.character,
                   closing.length >= fence.length, closing.isBare {
                    ranges.append(fence.start..<lineEnd)
                    openFence = nil
                }
            } else if let opening = fenceMarker(line) {
                openFence = (opening.character, opening.length, lineStart)
            } else {
                ranges.append(contentsOf: inlineCodeSpans(in: line))
            }
            lineStart = next
        }
        if let fence = openFence {
            ranges.append(fence.start..<text.endIndex)
        }
        return ranges
    }

    /// A fence line: up to 3 spaces, then 3+ backticks or tildes. `isBare`
    /// when only whitespace follows (required for a closing fence).
    private static func fenceMarker(_ line: Substring) -> (character: Character, length: Int, isBare: Bool)? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let after = rest.dropFirst(run.count)
        return (first, run.count, after.allSatisfy(\.isWhitespace))
    }

    /// Inline code spans on one line: a backtick run of length n up to the
    /// next run of exactly n. An unmatched run is literal text.
    private static func inlineCodeSpans(in line: Substring) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var index = line.startIndex
        while let open = line[index...].firstIndex(of: "`") {
            let openRun = line[open...].prefix(while: { $0 == "`" })
            var search = openRun.endIndex
            var closed = false
            while let candidate = line[search...].firstIndex(of: "`") {
                let closeRun = line[candidate...].prefix(while: { $0 == "`" })
                if closeRun.count == openRun.count {
                    spans.append(open..<closeRun.endIndex)
                    index = closeRun.endIndex
                    closed = true
                    break
                }
                search = closeRun.endIndex
            }
            if !closed { index = openRun.endIndex }
        }
        return spans
    }

    // MARK: - Links

    /// `text` with every label linked to `meetingID`; plain when `meetingID`
    /// is `nil` (no meeting to jump to).
    static func attributed(_ text: String, meetingID: UUID?) -> AttributedString {
        let plain = AttributedString(text)
        guard let meetingID else { return plain }
        return addingLinks(to: plain, meetingID: meetingID)
    }

    /// `attributed` with a `.link` on every label found in its characters.
    /// Other attributes (fonts from the markdown renderer) are kept.
    static func addingLinks(to attributed: AttributedString, meetingID: UUID) -> AttributedString {
        let plain = String(attributed.characters)
        let found = ranges(in: plain)
        guard !found.isEmpty else { return attributed }
        var result = attributed
        let scalars = plain.unicodeScalars
        for (range, seconds) in found {
            // Unicode-scalar offsets map exactly between the String and the
            // AttributedString (their Character views may be built differently).
            let lowerOffset = scalars.distance(from: scalars.startIndex, to: range.lowerBound)
            let length = scalars.distance(from: range.lowerBound, to: range.upperBound)
            let lower = result.unicodeScalars.index(result.startIndex, offsetBy: lowerOffset)
            let upper = result.unicodeScalars.index(lower, offsetBy: length)
            result[lower..<upper].link = url(meetingID: meetingID, seconds: seconds)
        }
        return result
    }

    /// `casablanca-timestamp://jump/<UUID>?t=<seconds>`.
    static func url(meetingID: UUID, seconds: Double) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        components.path = "/\(meetingID.uuidString)"
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let value = clamped.rounded(.towardZero) == clamped && clamped < 1e15
            ? String(Int64(clamped))
            : String(clamped)
        components.queryItems = [URLQueryItem(name: secondsQueryName, value: value)]
        // Scheme, host, a UUID path and a numeric query always form a URL.
        return components.url!
    }

    /// The meeting and seconds in a ``url(meetingID:seconds:)`` URL; `nil`
    /// for other schemes or hosts, a malformed id, or missing, negative or
    /// non-finite seconds.
    static func target(from url: URL) -> (meetingID: UUID, seconds: Double)? {
        guard url.scheme?.lowercased() == urlScheme,
              url.host?.lowercased() == urlHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let path = components.path
        guard path.hasPrefix("/"), let meetingID = UUID(uuidString: String(path.dropFirst())),
              let raw = components.queryItems?.first(where: { $0.name == secondsQueryName })?.value,
              let seconds = Double(raw), seconds.isFinite, seconds >= 0
        else { return nil }
        return (meetingID, seconds)
    }
}

/// Text whose `[mm:ss]` labels jump to that moment of `meetingID`. Needs
/// `handlesTimestampLinks()` above it (ContentView installs it for the window).
struct TimestampLinkText: View {
    let text: String
    let meetingID: UUID?

    var body: some View {
        Self.text(text, meetingID: meetingID)
    }

    /// The same as a `Text`, for callers that apply `Text`-only modifiers.
    static func text(_ text: String, meetingID: UUID?) -> Text {
        Text(TimestampLinks.attributed(text, meetingID: meetingID))
    }
}

extension View {
    /// Routes timestamp links in this subtree to `navigator`; every other
    /// URL goes to the system as before.
    func handlesTimestampLinks(_ navigator: MeetingDetailNavigator = .shared) -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard let target = TimestampLinks.target(from: url) else { return .systemAction }
            navigator.jump(to: target.meetingID, seconds: target.seconds)
            return .handled
        })
    }
}
