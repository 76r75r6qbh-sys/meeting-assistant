import Foundation

/// Parsed `refinement_prep` body (draftType `jira`). No body delimiter — the
/// entire item lives in the structured header block.
///
/// ```
/// Story: <IO-XXXX> — <title>
/// Current radio: <value-or-Unknown>
/// Proposed radio: <Yes-External|Yes-Internal|No>
/// Current priority: <value-or-Undefined>
/// Proposed priority: <High|Medium|Low>
/// Heuristic: <which rule fired>
/// Confidence: <high|medium|low>
/// Estimation: <value or "missing">
/// AC gaps: <comma-separated section names or "none">
/// Open comments: <count + @-mention names>
/// ```
///
/// Requires Story and Proposed radio. The Story line is split on the first
/// " — " (em dash) or " - " (hyphen) into key + title. `acGaps` is empty when
/// the value is "none".
struct RefinementPrepBody: Equatable {
    var storyKey: String
    var storyTitle: String
    var currentRadio: String
    var proposedRadio: String
    var currentPriority: String
    var proposedPriority: String
    var heuristic: String
    var confidence: String
    var estimation: String
    var acGaps: [String]
    var openComments: String

    init(
        storyKey: String,
        storyTitle: String = "",
        currentRadio: String = "",
        proposedRadio: String,
        currentPriority: String = "",
        proposedPriority: String = "",
        heuristic: String = "",
        confidence: String = "",
        estimation: String = "",
        acGaps: [String] = [],
        openComments: String = ""
    ) {
        self.storyKey = storyKey
        self.storyTitle = storyTitle
        self.currentRadio = currentRadio
        self.proposedRadio = proposedRadio
        self.currentPriority = currentPriority
        self.proposedPriority = proposedPriority
        self.heuristic = heuristic
        self.confidence = confidence
        self.estimation = estimation
        self.acGaps = acGaps
        self.openComments = openComments
    }

    init?(parsing raw: String) {
        let body = ActionBodyParsing.normalizeNewlines(raw)
        let (headers, _) = ActionBodyParsing.parseHeaders(body)
        guard let storyRaw = headers.nonEmpty("story"),
              let proposedRadio = headers.nonEmpty("proposed radio") else {
            return nil
        }

        let (key, title) = Self.splitStory(storyRaw)
        self.storyKey = key
        self.storyTitle = title
        self.currentRadio = headers["current radio"] ?? ""
        self.proposedRadio = proposedRadio
        self.currentPriority = headers["current priority"] ?? ""
        self.proposedPriority = headers["proposed priority"] ?? ""
        self.heuristic = headers["heuristic"] ?? ""
        self.confidence = headers["confidence"] ?? ""
        self.estimation = headers["estimation"] ?? ""

        let gapsRaw = headers["ac gaps"] ?? ""
        self.acGaps = gapsRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
            ? []
            : ActionBodyParsing.list(gapsRaw)

        self.openComments = headers["open comments"] ?? ""
    }

    /// Split a "Story" value on the first " — " (em dash) or " - " (hyphen).
    /// When no separator is present, the whole value is the key and the title
    /// is empty.
    private static func splitStory(_ raw: String) -> (key: String, title: String) {
        for separator in [" — ", " - "] {
            if let range = raw.range(of: separator) {
                let key = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (key, title)
            }
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func serialized() -> String {
        var lines: [String] = []
        let story = storyTitle.isEmpty ? storyKey : "\(storyKey) — \(storyTitle)"
        lines.append("Story: \(story)")
        lines.append("Current radio: \(currentRadio)")
        lines.append("Proposed radio: \(proposedRadio)")
        lines.append("Current priority: \(currentPriority)")
        lines.append("Proposed priority: \(proposedPriority)")
        lines.append("Heuristic: \(heuristic)")
        lines.append("Confidence: \(confidence)")
        lines.append("Estimation: \(estimation)")
        lines.append("AC gaps: \(acGaps.isEmpty ? "none" : ActionBodyParsing.joinList(acGaps))")
        lines.append("Open comments: \(openComments)")
        return lines.joined(separator: "\n")
    }
}
