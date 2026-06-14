import Foundation

/// Parsed `roadmap_commitment` body (draftType `jira`).
///
/// ```
/// Asker: <name>
/// Topic: <one-line summary>
/// Promised timeline: <Q3 2026 | release 2026.4 | "niet voor 2027" | etc.>
/// Source: Teams 1:1 — <permalink>
///
/// ---TICKET---
/// Project: <IO|MCPM|...>
/// Summary: <short Jira summary>
/// Description: <2–4 lines>
/// ```
///
/// Requires Asker and Promised timeline. `permalink` is the first URL found in
/// the Source line, if any. `ticket` is the slim ticket parse of the block after
/// `---TICKET---` (Project + Summary required there).
struct RoadmapCommitmentBody: Equatable {
    var asker: String
    var topic: String
    var promisedTimeline: String
    var sourceLine: String
    var permalink: String?
    var ticket: TicketDraftBody?

    init(
        asker: String,
        topic: String = "",
        promisedTimeline: String,
        sourceLine: String = "",
        permalink: String? = nil,
        ticket: TicketDraftBody? = nil
    ) {
        self.asker = asker
        self.topic = topic
        self.promisedTimeline = promisedTimeline
        self.sourceLine = sourceLine
        self.permalink = permalink
        self.ticket = ticket
    }

    init?(parsing body: String) {
        let (headers, after) = ActionBodyParsing.parseHeaders(body, bodyDelimiter: "---TICKET---")
        guard let asker = headers.nonEmpty("asker"),
              let promisedTimeline = headers.nonEmpty("promised timeline") else {
            return nil
        }
        self.asker = asker
        self.topic = headers["topic"] ?? ""
        self.promisedTimeline = promisedTimeline
        self.sourceLine = headers["source"] ?? ""
        self.permalink = ActionBodyParsing.firstURL(in: self.sourceLine)
        if let after {
            self.ticket = TicketDraftBody(parsingSlim: after)
        } else {
            self.ticket = nil
        }
    }

    func serialized() -> String {
        var lines: [String] = []
        lines.append("Asker: \(asker)")
        lines.append("Topic: \(topic)")
        lines.append("Promised timeline: \(promisedTimeline)")
        lines.append("Source: \(sourceLine)")
        if let ticket {
            lines.append("")
            lines.append("---TICKET---")
            // Serialize the slim ticket as Project / Summary / Description so it
            // round-trips through the slim parser.
            lines.append("Project: \(ticket.project)")
            lines.append("Summary: \(ticket.summary)")
            lines.append("Description: \(ticket.description)")
        }
        return lines.joined(separator: "\n")
    }
}
