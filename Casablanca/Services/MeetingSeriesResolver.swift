import Foundation
import SwiftData

/// Resolves recurring-meeting relationships between ``Meeting`` rows.
///
/// CRITICAL FACT: EventKit's `eventIdentifier` is SHARED across ALL occurrences
/// of a recurring event — it is NOT per-occurrence. So `Meeting.calendarEventID`
/// already IS the *series* identifier. Two occurrences of the same weekly meeting
/// therefore share a `calendarEventID` but differ in `date` (each occurrence's
/// start datetime). This resolver uses that pair to walk a series.
///
/// All predicates here are over scalar columns (`calendarEventID: String?`,
/// `date: Date`) so they CAN run as `#Predicate` SQL fetches — unlike the
/// `tags` array blob, which must be filtered in memory.
///
/// For meetings with no `calendarEventID` (manual meetings, or rows created
/// before series support existed) the organizer is not stored — only
/// `participants` — so the fallback key is the normalized (case-insensitive)
/// title. The fallback predicate cannot be expressed in `#Predicate`
/// (case-insensitive comparison + nil-id requirement), so it filters in memory.
enum MeetingSeriesResolver {
    /// Whether two meetings should be considered the SAME occurrence rather than
    /// two occurrences of the same series. Occurrences of a recurring event share
    /// `calendarEventID`; they are distinguished by their start `date`.
    static func isSameOccurrence(_ a: Meeting, asEventID eventID: String, occurrenceStart: Date) -> Bool {
        guard let id = a.calendarEventID, !id.isEmpty, id == eventID else { return false }
        // Compare at second granularity to match the disambiguation key used by
        // `findOrCreateMeeting` (see `Meeting.normalizedOccurrenceDate`), so a
        // sub-second-jittered `occurrenceStart` still resolves to the same row.
        return Meeting.normalizedOccurrenceDate(a.date) == Meeting.normalizedOccurrenceDate(occurrenceStart)
    }

    /// The PREVIOUS occurrence of `meeting`'s series: the most-recent meeting
    /// strictly before `meeting.date` that belongs to the same series.
    ///
    /// - When `meeting` has a non-empty `calendarEventID`, the series is matched
    ///   by that id (scalar `#Predicate`).
    /// - Otherwise it falls back to a normalized-title match across all meetings.
    @MainActor
    static func previousOccurrence(of meeting: Meeting, in context: ModelContext) -> Meeting? {
        candidates(for: meeting, in: context)
            .filter { $0.id != meeting.id && $0.date < meeting.date }
            .max { $0.date < $1.date }
    }

    /// The NEXT occurrence of `meeting`'s series: the earliest meeting strictly
    /// after `meeting.date` that belongs to the same series. Used by the detail
    /// inspector to offer a forward link.
    @MainActor
    static func nextOccurrence(of meeting: Meeting, in context: ModelContext) -> Meeting? {
        candidates(for: meeting, in: context)
            .filter { $0.id != meeting.id && $0.date > meeting.date }
            .min { $0.date < $1.date }
    }

    /// Fetch the set of meetings that belong to `meeting`'s series (excluding the
    /// directionality filter, which the callers apply). Series membership is by
    /// `calendarEventID` when present, else by normalized title.
    @MainActor
    private static func candidates(for meeting: Meeting, in context: ModelContext) -> [Meeting] {
        if let seriesID = meeting.calendarEventID, !seriesID.isEmpty {
            let descriptor = FetchDescriptor<Meeting>(
                predicate: #Predicate { $0.calendarEventID == seriesID }
            )
            return (try? context.fetch(descriptor)) ?? []
        }

        // Title fallback for manual / pre-series meetings: case-insensitive title
        // equality, restricted to rows without a calendar id (a recurring series
        // already matched by id above; a manual meeting that happens to share a
        // title with a calendar meeting should not be linked to it).
        let key = normalizedTitle(meeting.title)
        guard !key.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Meeting>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { candidate in
            let id = candidate.calendarEventID
            let hasNoCalendarID = (id == nil || id!.isEmpty)
            return hasNoCalendarID && normalizedTitle(candidate.title) == key
        }
    }

    /// Normalized series key for the title fallback: trimmed + case-insensitive.
    static func normalizedTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Action-item carry-over

    /// Build the markdown that carries the previous occurrence's OPEN (unchecked)
    /// action items into the prep notes. Returns `nil` when there is nothing to
    /// carry (no previous meeting, or no open todos) so callers can hide the card.
    ///
    /// This is a PURE function (no SwiftData fetch, no side effects): it only
    /// reads the previous meeting's `todos` and emits a `## From last time`
    /// checklist of the unchecked items. It deliberately does NOT create new
    /// `TodoItem`s — the carry-over only seeds the prep markdown so the user can
    /// edit/triage it freely.
    static func carryOverMarkdown(from previous: Meeting) -> String? {
        let openItems = openTodos(of: previous)
        guard !openItems.isEmpty else { return nil }
        let lines = openItems.map { "- [ ] \($0.text)" }
        return "## From last time\n" + lines.joined(separator: "\n")
    }

    /// The previous meeting's unchecked todos, in stable creation order. Exposed
    /// for the carry-over card's "N open action items" count.
    static func openTodos(of meeting: Meeting) -> [TodoItem] {
        meeting.todos
            .filter { !$0.isCompleted }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Append carry-over markdown to existing prep text, inserting a blank-line
    /// separator only when the existing text is non-empty. Pure + testable.
    static func appendingCarryOver(to existing: String, from previous: Meeting) -> String? {
        guard let block = carryOverMarkdown(from: previous) else { return nil }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return block }
        return existing + "\n\n" + block
    }
}
