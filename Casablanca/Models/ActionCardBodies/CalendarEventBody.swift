import Foundation

/// Parsed `calendar_event` body (draftType `calendar`).
///
/// ```
/// Subject: <title>
/// When: <YYYY-MM-DD HH:mm>–<HH:mm> (<TZ>)
/// Duration: <minutes>
/// Invitees: <comma-separated emails>
/// Location: <Teams link | room | "Microsoft Teams Meeting">
/// Agenda: <one or two lines>
/// ```
///
/// Requires Subject and When. `whenRaw` keeps the "When" value verbatim;
/// `dateText` and `timeRange` are best-effort parsed views of it. `duration` is
/// the minutes integer when present.
struct CalendarEventBody: Equatable {
    var subject: String
    var whenRaw: String
    var duration: Int?
    var invitees: [String]
    var location: String?
    var agenda: String

    /// Best-effort `YYYY-MM-DD` extracted from `whenRaw`, or nil.
    var dateText: String? {
        let parts = whenRaw.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let candidate = String(first)
        // Loose YYYY-MM-DD shape check.
        let comps = candidate.split(separator: "-")
        guard comps.count == 3, comps.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return candidate
    }

    /// Best-effort "HH:mm–HH:mm" range extracted from `whenRaw`, or nil.
    var timeRange: String? {
        // Take the substring after the date, strip a trailing "(TZ)".
        guard let spaceIndex = whenRaw.firstIndex(of: " ") else { return nil }
        var rest = String(whenRaw[whenRaw.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
        if let paren = rest.firstIndex(of: "(") {
            rest = String(rest[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return rest.isEmpty ? nil : rest
    }

    init(
        subject: String,
        whenRaw: String,
        duration: Int? = nil,
        invitees: [String] = [],
        location: String? = nil,
        agenda: String = ""
    ) {
        self.subject = subject
        self.whenRaw = whenRaw
        self.duration = duration
        self.invitees = invitees
        self.location = location
        self.agenda = agenda
    }

    init?(parsing raw: String) {
        let body = ActionBodyParsing.normalizeNewlines(raw)
        let (headers, _) = ActionBodyParsing.parseHeaders(body)
        guard let subject = headers.nonEmpty("subject"),
              let whenRaw = headers.nonEmpty("when") else {
            return nil
        }
        self.subject = subject
        self.whenRaw = whenRaw
        if let durationRaw = headers.nonEmpty("duration") {
            // Tolerate "30 minutes" / "30 min" by taking the leading integer.
            let digits = durationRaw.prefix { $0.isNumber }
            self.duration = Int(digits)
        } else {
            self.duration = nil
        }
        self.invitees = ActionBodyParsing.list(headers["invitees"])
        self.location = headers.nonEmpty("location")
        self.agenda = headers["agenda"] ?? ""
    }

    func serialized() -> String {
        var lines: [String] = []
        lines.append("Subject: \(subject)")
        lines.append("When: \(whenRaw)")
        if let duration { lines.append("Duration: \(duration)") }
        if !invitees.isEmpty { lines.append("Invitees: \(ActionBodyParsing.joinList(invitees))") }
        if let location { lines.append("Location: \(location)") }
        lines.append("Agenda: \(agenda)")
        return lines.joined(separator: "\n")
    }
}
