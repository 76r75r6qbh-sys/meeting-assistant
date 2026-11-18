import EventKit
import Foundation

/// One invitee of a meeting's calendar event.
struct MeetingAttendee: Equatable, Sendable {
    var name: String
    var email: String?
    var isCurrentUser: Bool
}

/// Where the summary prompt gets a meeting's attendees from. Injectable so tests
/// never touch EventKit or the user's calendar.
protocol MeetingAttendeeProviding {
    @MainActor func attendees(for meeting: Meeting) -> [MeetingAttendee]
}

/// Attendees of the meeting's calendar event. Returns `[]` unless
/// `meeting.calendarEventID` is set AND the app has full calendar access, so it
/// never triggers a permission prompt. The `EKEventStore` is created lazily, on
/// the first lookup that can succeed.
struct EventKitAttendeeProvider: MeetingAttendeeProviding {
    /// Shared so repeated summaries don't each spin up an event store.
    @MainActor private static var store: EKEventStore?

    @MainActor
    func attendees(for meeting: Meeting) -> [MeetingAttendee] {
        guard let identifier = meeting.calendarEventID, !identifier.isEmpty,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }
        let store = Self.store ?? EKEventStore()
        Self.store = store
        guard let event = store.event(withIdentifier: identifier) else { return [] }
        return (event.attendees ?? []).map { participant in
            MeetingAttendee(
                name: participant.name ?? "",
                email: Self.email(from: participant.url),
                isCurrentUser: participant.isCurrentUser
            )
        }
    }

    /// The address of a `mailto:` URL; nil for any other scheme.
    static func email(from url: URL) -> String? {
        let raw = url.absoluteString
        guard raw.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(raw.dropFirst("mailto:".count))
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? nil : address
    }
}

/// The parts of the summary prompt that say who was there and what the user
/// cares about (spec B4).
enum SummaryPromptContext {
    /// Focus block cap in a single pass / reduce.
    static let maxFocusTokens = 1_500
    /// Below this, go map-reduce instead of trimming the focus further.
    static let minFocusTokens = 200
    /// Focus cap inside each map prompt.
    static let mapFocusTokens = 300

    static let focusHeader = "What the user cares about (their prep and own notes for this meeting — use it to decide what matters, but only report what the transcript or notes support):"

    // MARK: - Participants

    /// `Name`, `Name <mail>`, `Name (me)` or `Name (me) <mail>`, joined by `, `.
    /// Starts from `participants`, adds e-mails of name-matching attendees,
    /// appends attendees not yet listed and marks the user. An empty list is
    /// `Unknown` — the user is never invented into an unknown room.
    static func participantsLine(
        participants: [String],
        attendees: [MeetingAttendee],
        userAliases: [String]
    ) -> String {
        struct Entry {
            var name: String
            var email: String?
            var isMe: Bool
        }

        func clean(_ text: String?) -> String? {
            guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        var entries = participants.compactMap(clean).map { Entry(name: $0, email: nil, isMe: false) }

        for attendee in attendees {
            let name = clean(attendee.name)
            let email = clean(attendee.email)
            if let name {
                let key = ActionItemOwnership.fold(name)
                if let index = entries.firstIndex(where: { ActionItemOwnership.fold($0.name) == key }) {
                    if entries[index].email == nil { entries[index].email = email }
                    if attendee.isCurrentUser { entries[index].isMe = true }
                } else {
                    entries.append(Entry(name: name, email: email, isMe: attendee.isCurrentUser))
                }
            } else if let email {
                // No name: the address stands in for it, once.
                let key = ActionItemOwnership.fold(email)
                if let index = entries.firstIndex(where: {
                    ActionItemOwnership.fold($0.name) == key || $0.email.map(ActionItemOwnership.fold) == key
                }) {
                    if attendee.isCurrentUser { entries[index].isMe = true }
                } else {
                    entries.append(Entry(name: email, email: nil, isMe: attendee.isCurrentUser))
                }
            }
        }

        for index in entries.indices where !entries[index].isMe {
            if ActionItemOwnership.owner(entries[index].name, matchesAnyOf: userAliases) {
                entries[index].isMe = true
            }
        }

        guard !entries.isEmpty else { return "Unknown" }

        if !entries.contains(where: \.isMe), let alias = userAliases.lazy.compactMap(clean).first {
            entries.append(Entry(name: alias, email: nil, isMe: true))
        }

        return entries.map { entry in
            var text = entry.name
            if entry.isMe { text += " (me)" }
            if let email = entry.email { text += " <\(email)>" }
            return text
        }
        .joined(separator: ", ")
    }

    // MARK: - Focus block

    /// The "What the user cares about" block: prep, then user notes, each part
    /// omitted when empty. `""` when both are empty. To fit `maxTokens`
    /// (`LLMPromptSupport.budgetTokens`) the prep is cut at its tail first, then
    /// the notes, each ending in `…`.
    static func focusBlock(prep: String?, notes: String?, maxTokens: Int) -> String {
        var prep = prep?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prep.isEmpty || !notes.isEmpty, maxTokens > 0 else { return "" }

        let maxChars = maxTokens * LLMPromptSupport.budgetCharsPerToken
        func fits(_ block: String) -> Bool { LLMPromptSupport.budgetTokens(block) <= maxTokens }

        var block = render(prep: prep, notes: notes)
        if fits(block) { return block }

        // Prep first: the room it has is what is left after the labels and notes.
        prep = cut(prep, toChars: maxChars - (block.count - prep.count))
        block = render(prep: prep, notes: notes)
        if fits(block) { return block }

        // The prep is gone; now the notes.
        prep = ""
        let withoutPrep = render(prep: "", notes: notes)
        notes = cut(notes, toChars: maxChars - (withoutPrep.count - notes.count))
        guard !notes.isEmpty else { return "" }
        block = render(prep: prep, notes: notes)
        return fits(block) ? block : ""
    }

    private static func render(prep: String, notes: String) -> String {
        guard !prep.isEmpty || !notes.isEmpty else { return "" }
        var block = focusHeader
        if !prep.isEmpty { block += "\nPrep:\n" + prep }
        if !notes.isEmpty { block += "\nUser notes:\n" + notes }
        return block
    }

    /// `text` cut at its tail to at most `limit` characters, ending in `…`; `""`
    /// when there is no room for anything but the ellipsis.
    private static func cut(_ text: String, toChars limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return "" }
        let kept = String(text.prefix(limit - 1))
        let trimmed = kept.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trimmed.isEmpty ? "" : trimmed + "…"
    }
}
