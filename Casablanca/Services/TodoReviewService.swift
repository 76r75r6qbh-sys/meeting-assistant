// Casablanca/Services/TodoReviewService.swift
import Foundation
import SwiftData

/// Which extracted action items become proposed to-dos for the user.
enum ProposedTodoPlanner {
    /// The user's own items (an owner matching one of `aliases`), plus the
    /// items without an owner when `includeUnassigned`.
    static func itemsToPropose(
        _ items: [ExtractedActionItem],
        aliases: [String],
        includeUnassigned: Bool
    ) -> [ExtractedActionItem] {
        items.filter { item in
            guard !item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let owner = item.owner else { return includeUnassigned }
            return ActionItemOwnership.owner(owner, matchesAnyOf: aliases)
        }
    }
}

/// Review of extracted to-dos. Proposed to-dos live in SwiftData only
/// (`status == .proposed`, `sourceFilePath == nil`): they never reach the
/// vault, Apple Notes or an export until they are accepted.
@MainActor
enum TodoReviewService {
    /// Replaces the meeting's pending proposals with one `.proposed` to-do per
    /// item. Accepted and rejected to-dos are kept; an item whose task equals
    /// (trimmed) the text of one of them is not proposed again, nor is an
    /// exact repeat within `items`. Does not save.
    static func replaceProposedTodos(
        for meeting: Meeting,
        with items: [ExtractedActionItem],
        in context: ModelContext
    ) throws {
        let existing = meeting.todos
        var seen = Set<String>()
        for todo in existing {
            if todo.status == .proposed {
                context.delete(todo)
            } else {
                seen.insert(todo.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        for item in items {
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, seen.insert(task).inserted else { continue }
            let todo = TodoItem(text: task, isCompleted: false, sourceFilePath: nil, meeting: meeting)
            todo.owner = item.owner
            todo.dueDate = item.due.flatMap(dueDate(fromISO:))
            todo.sourceTimestamp = item.timestamp
            todo.quote = item.quote
            todo.status = .proposed
            todo.verification = item.verified
            context.insert(todo)
        }
    }

    /// `yyyy-MM-dd` as local midnight; `nil` when it does not parse.
    static func dueDate(fromISO iso: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: iso) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }
}
