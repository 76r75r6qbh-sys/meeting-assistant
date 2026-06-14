import Foundation

/// Parsed `topdesk_response` body (draftType `topdesk`).
///
/// ```
/// MC-ref: <MCxxxx xxxx>
/// Customer: <customer name>
/// Caller: <caller name + email if known>
/// Visibility: <visible-to-caller|internal-only>
/// Add Jira link: <issue key or "none">
///
/// ---RESPONSE---
/// <reply body in Dutch>
/// ```
///
/// Requires MC-ref and Customer. `addJiraLink` is nil when the value is "none".
/// `response` is everything after `---RESPONSE---`, verbatim.
struct TopdeskResponseBody: Equatable {
    enum Visibility: Equatable {
        case visibleToCaller
        case internalOnly

        init(parsing raw: String) {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "internal-only": self = .internalOnly
            case "visible-to-caller": self = .visibleToCaller
            // Unrecognized → default to visible-to-caller (but still record it).
            default: self = .visibleToCaller
            }
        }

        var serialized: String {
            switch self {
            case .visibleToCaller: return "visible-to-caller"
            case .internalOnly: return "internal-only"
            }
        }
    }

    var mcRef: String
    var customer: String
    var caller: String?
    var visibility: Visibility
    var addJiraLink: String?
    var response: String

    init(
        mcRef: String,
        customer: String,
        caller: String? = nil,
        visibility: Visibility = .visibleToCaller,
        addJiraLink: String? = nil,
        response: String = ""
    ) {
        self.mcRef = mcRef
        self.customer = customer
        self.caller = caller
        self.visibility = visibility
        self.addJiraLink = addJiraLink
        self.response = response
    }

    init?(parsing body: String) {
        let (headers, after) = ActionBodyParsing.parseHeaders(body, bodyDelimiter: "---RESPONSE---")
        guard let mcRef = headers.nonEmpty("mc-ref"),
              let customer = headers.nonEmpty("customer") else {
            return nil
        }
        self.mcRef = mcRef
        self.customer = customer
        self.caller = headers.nonEmpty("caller")
        self.visibility = Visibility(parsing: headers["visibility"] ?? "")
        if let raw = headers.nonEmpty("add jira link"), raw.lowercased() != "none" {
            self.addJiraLink = raw
        } else {
            self.addJiraLink = nil
        }
        self.response = after ?? ""
    }

    func serialized() -> String {
        var lines: [String] = []
        lines.append("MC-ref: \(mcRef)")
        lines.append("Customer: \(customer)")
        if let caller { lines.append("Caller: \(caller)") }
        lines.append("Visibility: \(visibility.serialized)")
        lines.append("Add Jira link: \(addJiraLink ?? "none")")
        lines.append("")
        lines.append("---RESPONSE---")
        lines.append(response)
        return lines.joined(separator: "\n")
    }
}
