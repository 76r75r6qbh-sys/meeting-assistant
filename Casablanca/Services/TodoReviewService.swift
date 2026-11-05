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
    /// item. Accepted and rejected to-dos are kept, and an item that is a
    /// `FuzzyText.isFuzzyEqual` match of one of them is not proposed again.
    /// A kept to-do is compared by its text and by its bare action
    /// (`**owner** —` prefix and ` (date) [mm:ss]` suffix removed), because a
    /// to-do checked off in the summary tab stores the whole bullet. Repeats
    /// within `items` are dropped the same way. Does not save.
    static func replaceProposedTodos(
        for meeting: Meeting,
        with items: [ExtractedActionItem],
        in context: ModelContext
    ) throws {
        let existing = meeting.todos
        var seen: [String] = []
        for todo in existing {
            if todo.status == .proposed {
                context.delete(todo)
            } else {
                seen += comparableTexts(of: todo.text)
            }
        }

        for item in items {
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, !seen.contains(where: { FuzzyText.isFuzzyEqual($0, task) }) else { continue }
            seen.append(task)
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

    /// A kept to-do's text as stored and as its bare action.
    private static func comparableTexts(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = ActionItemRendering.strippingSuffix(ActionItemOwnership.parse(trimmed).action)
        return bare == trimmed || bare.isEmpty ? [trimmed] : [trimmed, bare]
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

/// Which meeting to-do a summary action-item bullet stands for.
enum ActionItemTodoMatcher {
    /// The to-do whose text is the bullet, its action without the `**owner** —`
    /// prefix, or that action without the rendered ` (yyyy-MM-dd) [mm:ss]`
    /// suffix. Rejected to-dos never match. An accepted match wins over a
    /// proposed one, so a checked item never shows "In review"; within a
    /// status the oldest row wins (then the lowest id), whatever the order of
    /// `todos`.
    static func matchingTodo(for text: String, in todos: [TodoItem]) -> TodoItem? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = ActionItemOwnership.parse(target).action
        let candidates: Set<String> = [target, action, ActionItemRendering.strippingSuffix(action)]
        return todos
            .filter { $0.status != .rejected && candidates.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .min { a, b in
                let rankA = a.status == .accepted ? 0 : 1
                let rankB = b.status == .accepted ? 0 : 1
                if rankA != rankB { return rankA < rankB }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id.uuidString < b.id.uuidString
            }
    }
}
