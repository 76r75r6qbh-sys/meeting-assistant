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
    /// item (regeneration rules, spec B6). Accepted and rejected to-dos are
    /// kept, and an item that is a `FuzzyText.isFuzzyEqual` match of one of
    /// them is not proposed again — the same guarded rule as every other
    /// merge, so short texts (< 12 characters) and texts whose digit tokens
    /// differ only match exactly. Each to-do carries its item's verification
    /// verdict (`verification`); the verdict's reason stays on
    /// `meeting.actionItems` and reaches only the decision log.
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
    nonisolated static func comparableTexts(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = ActionItemRendering.strippingSuffix(ActionItemOwnership.parse(trimmed).action)
        return bare == trimmed || bare.isEmpty ? [trimmed] : [trimmed, bare]
    }

    // MARK: - Review decisions

    /// Accepts a proposed (or rejected) to-do. With Obsidian storage and
    /// resolvable meeting files its line — with the ` — owner 📅 due [time]`
    /// suffix — is appended to the meeting's canonical to-do file and
    /// `sourceFilePath` is set; otherwise (local storage, no vault, no
    /// meeting) only SwiftData changes. Then `status = .accepted`, save, and
    /// one `.accept` (or `.autoAccept` when `auto`) log line. An already
    /// accepted to-do is left alone.
    static func accept(
        _ todo: TodoItem,
        in context: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        log: TodoDecisionLog = .shared,
        auto: Bool = false
    ) throws {
        guard todo.status != .accepted else { return }
        try ObsidianTodoSyncService.writeAcceptedMeetingTodo(
            todo, in: context, userDefaults: userDefaults, fileManager: fileManager
        )
        todo.status = .accepted
        try context.save()
        log.append(entry(for: todo, action: auto ? .autoAccept : .accept))
    }

    /// Rejects a proposed to-do: `status = .rejected`, save, log. Never
    /// touches files. Accepted to-dos are deleted, not rejected, so they are
    /// left alone (a vault line would otherwise bring them back).
    static func reject(_ todo: TodoItem, in context: ModelContext, log: TodoDecisionLog = .shared) throws {
        guard todo.status == .proposed else { return }
        todo.status = .rejected
        try context.save()
        log.append(entry(for: todo, action: .reject))
    }

    /// Edits a proposed to-do's text, owner and due date and logs `.edit`
    /// with only the fields that changed; does not accept. A blank `task`
    /// keeps the current text; a blank `owner` clears it. Non-proposed
    /// to-dos and edits that change nothing are ignored.
    static func edit(
        _ todo: TodoItem,
        task: String,
        owner: String?,
        dueDate: Date?,
        in context: ModelContext,
        log: TodoDecisionLog = .shared
    ) throws {
        guard todo.status == .proposed else { return }
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = trimmedTask.isEmpty ? todo.text : trimmedTask
        let newOwner = owner.flatMap(sanitizedOwner)
        let newDue = dueDate.map { Calendar.current.startOfDay(for: $0) }

        var changes: [String: TodoDecisionEntry.Change] = [:]
        if newText != todo.text { changes["task"] = .init(from: todo.text, to: newText) }
        if newOwner != todo.owner { changes["owner"] = .init(from: todo.owner, to: newOwner) }
        let oldDueText = todo.dueDate.map(ObsidianTodoMarkdown.isoDay)
        let newDueText = newDue.map(ObsidianTodoMarkdown.isoDay)
        if oldDueText != newDueText { changes["due"] = .init(from: oldDueText, to: newDueText) }
        guard !changes.isEmpty else { return }

        todo.text = newText
        todo.owner = newOwner
        todo.dueDate = newDue
        try context.save()
        var logged = entry(for: todo, action: .edit)
        logged.edit = changes
        log.append(logged)
    }

    /// An owner that round-trips through the vault line's ` — owner` suffix:
    /// `—` becomes `-`, line breaks become spaces, trimmed, at most 60
    /// characters; `nil` when blank.
    static func sanitizedOwner(_ owner: String) -> String? {
        let cleaned = owner
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// Accepts every `.proposed` to-do of `meeting` whose verification is
    /// `.supported` (oldest first) and returns how many were accepted.
    @discardableResult
    static func acceptAllVerified(
        in meeting: Meeting,
        in context: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        log: TodoDecisionLog = .shared,
        auto: Bool = false
    ) throws -> Int {
        let verified = meeting.todos
            .filter { $0.status == .proposed && $0.verification == .supported }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        for todo in verified {
            try accept(todo, in: context, userDefaults: userDefaults, fileManager: fileManager, log: log, auto: auto)
        }
        return verified.count
    }

    /// The decision-log entry for `todo` as it is now. The verification
    /// reason comes from the meeting's extracted item with the same task
    /// (or, after an edit, the same quote and timestamp).
    private static func entry(for todo: TodoItem, action: TodoDecisionEntry.Action) -> TodoDecisionEntry {
        let items = todo.meeting?.actionItems ?? []
        let source = items.first { $0.task.trimmingCharacters(in: .whitespacesAndNewlines) == todo.text }
            ?? items.first { todo.quote != nil && $0.quote == todo.quote && $0.timestamp == todo.sourceTimestamp }
        return TodoDecisionEntry(
            date: Date(),
            meetingID: todo.meeting?.id,
            todoID: todo.id,
            action: action,
            item: .init(
                task: todo.text,
                owner: todo.owner,
                due: todo.dueDate.map(ObsidianTodoMarkdown.isoDay),
                timestamp: todo.sourceTimestamp,
                quote: todo.quote
            ),
            edit: nil,
            verification: todo.verificationRaw,
            verificationReason: source?.verificationReason
        )
    }

    /// `yyyy-MM-dd` as local midnight; `nil` when it does not parse.
    nonisolated static func dueDate(fromISO iso: String) -> Date? {
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
        // Both sides as text and as bare action, so a row holding the whole
        // bullet (any owner/suffix form) or only the action matches.
        return todos
            .filter { todo in
                todo.status != .rejected
                    && TodoReviewService.comparableTexts(of: todo.text).contains(where: candidates.contains)
            }
            .min { a, b in
                let rankA = a.status == .accepted ? 0 : 1
                let rankB = b.status == .accepted ? 0 : 1
                if rankA != rankB { return rankA < rankB }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id.uuidString < b.id.uuidString
            }
    }
}
