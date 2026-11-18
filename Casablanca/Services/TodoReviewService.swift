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
            todo.owner = item.owner.flatMap(sanitizedOwner)
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
    nonisolated static func sanitizedOwner(_ owner: String) -> String? {
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
    /// Who an item belongs to, for matching.
    private enum OwnerKey: Equatable {
        /// `**?** —`, or an owner field such as `?`, `-` or `unknown`: explicitly nobody.
        case unassigned
        /// A named owner (never an empty token list); `raw` is kept to
        /// recognise a 60-character cut.
        case named(raw: String, tokens: [String])

        /// `.unassigned` for a value in `ActionItemOwnership.unassignedOwners`
        /// or one without any word token.
        init(named raw: String) {
            let tokens = ActionItemOwnership.tokens(raw)
            if tokens.isEmpty || ActionItemOwnership.unassignedOwners.contains(ActionItemOwnership.fold(raw)) {
                self = .unassigned
            } else {
                self = .named(raw: raw, tokens: tokens)
            }
        }

        /// How well two owners agree; `nil` when they are different owners.
        enum Agreement: Int, Comparable {
            /// Equal word tokens or both unassigned (and, in the matcher, a
            /// wildcard or an identical text).
            case full = 0
            /// Only by containment or a 60-character cut.
            case partial = 1

            static func < (a: Agreement, b: Agreement) -> Bool { a.rawValue < b.rawValue }
        }

        /// Same owner: equal word tokens (`.full`); one token list contained
        /// in the other (`Youri` / `Youri Broekhuizen`, as
        /// `ActionItemOwnership.owner(_:matchesAnyOf:)`); or one a prefix of
        /// the other, its last token possibly cut short when that owner is
        /// exactly 60 characters (`TodoReviewService.sanitizedOwner`).
        func agreement(with other: OwnerKey) -> Agreement? {
            switch (self, other) {
            case (.unassigned, .unassigned):
                return .full
            case let (.named(rawA, a), .named(rawB, b)):
                if a == b { return .full }
                if ActionItemOwnership.owner(rawA, matchesAnyOf: [rawB])
                    || ActionItemOwnership.owner(rawB, matchesAnyOf: [rawA]) {
                    return .partial
                }
                let (short, shortRaw, long) = a.count <= b.count ? (a, rawA, b) : (b, rawB, a)
                guard shortRaw.count == 60 else { return nil }
                let last = short.count - 1
                return Array(short[..<last]) == Array(long[..<last]) && long[last].hasPrefix(short[last])
                    ? .partial : nil
            default:
                return nil
            }
        }
    }

    /// The owner of a `**owner** —` prefix (`.unassigned` for `**?** —`);
    /// `nil` when the text has no owner prefix.
    private static func prefixOwner(of text: String) -> OwnerKey? {
        let parsed = ActionItemOwnership.parse(text)
        guard parsed.action != text else { return nil }
        return parsed.owner.map(OwnerKey.init(named:)) ?? .unassigned
    }

    /// The `[mm:ss]` label at the end of a bullet, if any.
    private static func trailingTimestamp(of text: String) -> String? {
        guard let range = text.range(of: #" \[[0-9:]+\]$"#, options: .regularExpression) else { return nil }
        let label = String(text[range].dropFirst(2).dropLast())
        return TranscriptLineFormat.seconds(fromLabel: label) != nil ? label : nil
    }

    /// Two timestamp labels name the same moment (`0:20` == `00:20`); labels
    /// that do not parse compare as text.
    private static func sameTimestamp(_ a: String, _ b: String) -> Bool {
        if let secondsA = TranscriptLineFormat.seconds(fromLabel: a),
           let secondsB = TranscriptLineFormat.seconds(fromLabel: b) {
            return secondsA == secondsB
        }
        return a == b
    }

    /// A row that matched, and how well, for picking among several.
    private struct Match {
        let todo: TodoItem
        let owner: OwnerKey.Agreement
        let sameTimestamp: Bool
    }

    /// The to-do whose text is the bullet, its action without the `**owner** —`
    /// prefix, or that action without the rendered ` (yyyy-MM-dd) [mm:ss]`
    /// suffix. Rejected to-dos never match. Among several matches: a row
    /// whose owner matches only by containment or a 60-character cut loses
    /// to any other (equal tokens, a wildcard, an identical text); then an
    /// accepted row beats a proposed one, so a checked item never shows
    /// "In review"; then a row whose `sourceTimestamp` is the bullet's wins;
    /// then the oldest row (then the lowest id), whatever the order of `todos`.
    static func matchingTodo(for text: String, in todos: [TodoItem]) -> TodoItem? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = ActionItemOwnership.parse(target).action
        let candidates: Set<String> = [target, action, ActionItemRendering.strippingSuffix(action)]
        let bulletOwner = prefixOwner(of: target)
        let bulletTimestamp = trailingTimestamp(of: target)
        // Both sides as text and as bare action, so a row holding the whole
        // bullet (any owner/suffix form) or only the action matches — for
        // the same owner only. The row's owner is its owner field, else —
        // only when the row stores the whole bullet, i.e. its text (or that
        // without the suffix) is not one of the bullet's own texts — its
        // bullet prefix; a row storing only the action keeps its bold text
        // as emphasis. A bullet without a prefix matches any owner. A row
        // with no owner matches any owner, but when it has a timestamp only
        // a bullet at that timestamp (or without one). An identical text
        // always matches.
        let matches: [Match] = todos.compactMap { todo in
            guard todo.status != .rejected else { return nil }
            let rowText = todo.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let atBulletTimestamp = todo.sourceTimestamp.flatMap { row in bulletTimestamp.map { sameTimestamp(row, $0) } } ?? false
            if rowText == target { return Match(todo: todo, owner: .full, sameTimestamp: atBulletTimestamp) }
            guard TodoReviewService.comparableTexts(of: rowText).contains(where: candidates.contains) else { return nil }
            let storesAction = candidates.contains(rowText)
                || candidates.contains(ActionItemRendering.strippingSuffix(rowText))
            let rowOwner = todo.owner.map(OwnerKey.init(named:)) ?? (storesAction ? nil : prefixOwner(of: rowText))
            guard let rowOwner else {
                if let rowTimestamp = todo.sourceTimestamp, let bulletTimestamp,
                   !sameTimestamp(rowTimestamp, bulletTimestamp) {
                    return nil
                }
                return Match(todo: todo, owner: .full, sameTimestamp: atBulletTimestamp)
            }
            guard let bulletOwner else { return Match(todo: todo, owner: .full, sameTimestamp: atBulletTimestamp) }
            guard let agreement = rowOwner.agreement(with: bulletOwner) else { return nil }
            return Match(todo: todo, owner: agreement, sameTimestamp: atBulletTimestamp)
        }
        return matches.min { a, b in
            if a.owner != b.owner { return a.owner < b.owner }
            let rankA = a.todo.status == .accepted ? 0 : 1
            let rankB = b.todo.status == .accepted ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            if a.sameTimestamp != b.sameTimestamp { return a.sameTimestamp }
            if a.todo.createdAt != b.todo.createdAt { return a.todo.createdAt < b.todo.createdAt }
            return a.todo.id.uuidString < b.todo.id.uuidString
        }?.todo
    }
}
