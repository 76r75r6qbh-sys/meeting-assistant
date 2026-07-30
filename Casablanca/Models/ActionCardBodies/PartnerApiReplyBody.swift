import Foundation

// MARK: - PartnerApiReplyBody

/// Parsed `partner_api_reply` body (draftType `email`).
///
/// ```
/// To: <recipient email>
/// Cc: <optional, comma-separated>
/// Subject: <subject line>
///
/// <email body, possibly multi-line>
/// ```
///
/// Requires `To` and `Subject`. `bodyText` is everything after the first blank
/// line, preserved verbatim (including internal blank lines).
struct PartnerApiReplyBody: Equatable {
    var to: String
    var cc: [String]
    var subject: String
    var bodyText: String

    init(to: String, cc: [String] = [], subject: String, bodyText: String) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.bodyText = bodyText
    }

    init?(parsing raw: String) {
        let body = ActionBodyParsing.normalizeNewlines(raw)
        let (headers, _) = ActionBodyParsing.parseHeaders(body)
        guard let to = headers.nonEmpty("to"),
              let subject = headers.nonEmpty("subject") else {
            return nil
        }
        self.to = to
        self.cc = ActionBodyParsing.list(headers["cc"])
        self.subject = subject
        self.bodyText = ActionBodyParsing.bodyAfterFirstBlankLine(body)
    }

    func serialized() -> String {
        var lines: [String] = []
        lines.append("To: \(to)")
        if !cc.isEmpty {
            lines.append("Cc: \(ActionBodyParsing.joinList(cc))")
        }
        lines.append("Subject: \(subject)")
        lines.append("")
        lines.append(bodyText)
        return lines.joined(separator: "\n")
    }
}
