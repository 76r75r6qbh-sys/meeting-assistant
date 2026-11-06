import Foundation

enum ObsidianTodoMarkdown {
    struct TaskLine: Equatable {
        let id: UUID?
        /// The task without its ` — owner 📅 due [timestamp]` suffix.
        let text: String
        let isCompleted: Bool
        var owner: String? = nil
        /// `yyyy-MM-dd`.
        var due: String? = nil
        /// Transcript timestamp label (`mm:ss` or `h:mm:ss`).
        var timestamp: String? = nil

        /// `true` when the line carried (or will carry) a suffix.
        var hasSuffix: Bool { !ObsidianTodoMarkdown.suffix(owner: owner, due: due, timestamp: timestamp).isEmpty }

        /// The same task with another id; suffix fields are kept.
        func withID(_ id: UUID) -> TaskLine {
            TaskLine(id: id, text: text, isCompleted: isCompleted, owner: owner, due: due, timestamp: timestamp)
        }
    }

    // MARK: - Suffix ` — <owner> 📅 <yyyy-MM-dd> [<label>]`

    /// The suffix written after a task's text: `""`, or e.g.
    /// `" — Youri 📅 2026-11-06 [12:34]"`. Each part is written only when set
    /// and valid; the owner only together with a due date or timestamp (and
    /// only when it is 1–60 characters without `—`), so the line parses back
    /// unambiguously and a user-typed `Bel Kim — dringend` is never read as an
    /// owner.
    static func suffix(owner: String?, due: String?, timestamp: String?) -> String {
        let due = due.flatMap { isISODay($0) ? $0 : nil }
        let timestamp = timestamp.flatMap { TranscriptLineFormat.seconds(fromLabel: $0) != nil ? $0 : nil }
        guard due != nil || timestamp != nil else { return "" }
        var out = ""
        if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), isValidOwner(owner) {
            out += " — \(owner)"
        }
        if let due { out += " 📅 \(due)" }
        if let timestamp { out += " [\(timestamp)]" }
        return out
    }

    /// The suffix for a stored to-do (`dueDate` as local `yyyy-MM-dd`).
    static func suffix(for todo: TodoItem) -> String {
        suffix(owner: todo.owner, due: todo.dueDate.map(isoDay), timestamp: todo.sourceTimestamp)
    }

    /// A to-do as a task line, suffix fields included.
    static func taskLine(for todo: TodoItem) -> TaskLine {
        TaskLine(
            id: todo.id, text: todo.text, isCompleted: todo.isCompleted,
            owner: todo.owner, due: todo.dueDate.map(isoDay), timestamp: todo.sourceTimestamp
        )
    }

    /// `date` as `yyyy-MM-dd` in the current time zone.
    static func isoDay(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// A real `yyyy-MM-dd` date (`2026-02-30` is not), so an impossible date
    /// stays in the text instead of vanishing on a re-render.
    private static func isISODay(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            && TodoReviewService.dueDate(fromISO: text) != nil
    }

    private static func isValidOwner(_ owner: String) -> Bool {
        (1...60).contains(owner.count) && !owner.contains("—") && !owner.contains(where: \.isNewline)
    }

    /// Splits a parsed task text from the end: optional ` [<label>]`, then
    /// optional ` 📅 yyyy-MM-dd`, then — only if one of those matched —
    /// optional ` — <owner>`. Anything else stays in the text. A text that
    /// starts with a bullet owner prefix (`**Youri** — …`, as
    /// `ActionItemOwnership.parse` recognises it) is a summary-tab to-do that
    /// stores the whole bullet: nothing is split off it.
    static func splittingSuffix(_ text: String) -> (text: String, owner: String?, due: String?, timestamp: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ActionItemOwnership.parse(trimmed).action == trimmed else { return (text, nil, nil, nil) }
        var rest = text
        var timestamp: String?
        var due: String?
        var owner: String?

        if rest.hasSuffix("]"), let open = rest.range(of: " [", options: .backwards) {
            let label = String(rest[open.upperBound..<rest.index(before: rest.endIndex)])
            if TranscriptLineFormat.seconds(fromLabel: label) != nil {
                timestamp = label
                rest = String(rest[..<open.lowerBound])
            }
        }
        if let marker = rest.range(of: " 📅 ", options: .backwards) {
            let candidate = String(rest[marker.upperBound...])
            if isISODay(candidate) {
                due = candidate
                rest = String(rest[..<marker.lowerBound])
            }
        }
        if due != nil || timestamp != nil, let dash = rest.range(of: " — ", options: .backwards) {
            let candidate = String(rest[dash.upperBound...])
            let remaining = String(rest[..<dash.lowerBound])
            if isValidOwner(candidate), candidate == candidate.trimmingCharacters(in: .whitespaces),
               !remaining.trimmingCharacters(in: .whitespaces).isEmpty, !remaining.hasSuffix("**") {
                owner = candidate
                rest = remaining
            }
        }
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return (text, nil, nil, nil) }
        return (rest, owner, due, timestamp)
    }

    struct GenericDocument: Equatable {
        var openTasks: [TaskLine]
        var doneTasks: [TaskLine]
    }

    private static let taskExpression = try! NSRegularExpression(
        pattern: #"^- \[( |x)\] (.+?)(?: <!-- casablanca-todo: ([A-F0-9-]+) -->)?$"#,
        options: [.caseInsensitive]
    )

    static func parseGenericDocument(_ markdown: String) -> GenericDocument {
        GenericDocument(
            openTasks: parseTasks(in: section(named: "Open", from: markdown)),
            doneTasks: parseTasks(in: section(named: "Done", from: markdown))
        )
    }

    static func parseMeetingActionItems(_ markdown: String) -> [TaskLine] {
        parseTasks(in: section(named: "Action Items", from: markdown))
    }

    static func renderGenericDocument(openTasks: [TaskLine], doneTasks: [TaskLine]) -> String {
        """
        # Casablanca Todos

        ## Open

        \(render(openTasks))

        ## Done

        \(render(doneTasks))
        """
    }

    /// Non-task lines under `## Action Items` (outer blank lines trimmed), or
    /// nil when the markdown has no such heading.
    static func meetingActionItemsNonTaskLines(_ markdown: String) -> [String]? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "## Action Items" }) else {
            return nil
        }
        var nonTaskLines = section(named: "Action Items", from: markdown)
            .components(separatedBy: .newlines)
            .filter { parseTaskLine($0) == nil }
        while nonTaskLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { nonTaskLines.removeFirst() }
        while nonTaskLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { nonTaskLines.removeLast() }
        return nonTaskLines
    }

    static func renderMeetingDocument(_ markdown: String, actionItems: [TaskLine], trailingLines: [String] = []) -> String {
        var replacementLines = meetingSectionLines(tasks: actionItems)
        if !trailingLines.isEmpty {
            replacementLines.append("")
            replacementLines.append(contentsOf: trailingLines)
        }
        let lines = markdown.components(separatedBy: .newlines)

        guard let startIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Action Items" }) else {
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            let block = replacementLines.joined(separator: "\n")
            guard !trimmed.isEmpty else {
                return block
            }
            return "\(trimmed)\n\n\(block)"
        }

        var endIndex = lines.endIndex
        for index in lines.index(after: startIndex)..<lines.endIndex where isSectionBoundary(lines[index]) {
            endIndex = index
            break
        }

        var updatedLines = Array(lines[..<startIndex])
        updatedLines.append(contentsOf: replacementLines)
        if endIndex < lines.endIndex {
            updatedLines.append(contentsOf: lines[endIndex...])
        }

        return updatedLines.joined(separator: "\n")
    }

    // MARK: - In-place edits of a meeting file's `## Action Items`
    //
    // These touch only the task lines they target. Every other line — nested
    // sub-bullets, free text, `* [ ]` / `- [/]` tasks, `###` sub-headings, other
    // sections, CRLF line endings — is preserved byte-for-byte. Prefer these over
    // `renderMeetingDocument`, which rebuilds the whole section and is only meant
    // for the exporter's regenerate-and-merge path.

    /// Flips the checkbox of the task carrying `id`. Returns nil when no task
    /// line under `## Action Items` carries that id (nothing to write).
    static func settingTaskCompletion(_ markdown: String, id: UUID, isCompleted: Bool) -> String? {
        var lines = markdown.components(separatedBy: "\n")
        guard let index = actionItemTaskLineIndices(in: lines).first(where: { $0.task.id == id })?.index else {
            return nil
        }
        // `taskExpression` anchors on `- [` so the marker is always the 4th character.
        var characters = Array(lines[index])
        characters[3] = isCompleted ? "x" : " "
        lines[index] = String(characters)
        return lines.joined(separator: "\n")
    }

    /// Removes the single task line carrying `id`. Lines nested under it are
    /// kept (user-written detail is never dropped). Returns nil when absent.
    static func removingTask(_ markdown: String, id: UUID) -> String? {
        var lines = markdown.components(separatedBy: "\n")
        guard let index = actionItemTaskLineIndices(in: lines).first(where: { $0.task.id == id })?.index else {
            return nil
        }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// Appends `task` to `## Action Items`: right after the section's last
    /// checkbox item (and the indented lines nested under it), else after the
    /// section's last non-blank line. Creates the section at the end of the
    /// document when it is missing.
    static func appendingTask(_ markdown: String, _ task: TaskLine) -> String {
        let rendered = render([task])
        var lines = markdown.components(separatedBy: "\n")

        guard let start = actionItemsHeadingIndex(in: lines) else {
            if markdown.isEmpty { return "## Action Items\n\n\(rendered)\n" }
            let separator = markdown.hasSuffix("\n") ? "\n" : "\n\n"
            return "\(markdown)\(separator)## Action Items\n\n\(rendered)\n"
        }

        let end = sectionEnd(in: lines, after: start)
        let body = (start + 1)..<end
        let isBlank: (Int) -> Bool = { stripCR(lines[$0]).trimmingCharacters(in: .whitespaces).isEmpty }
        var anchor = body.last(where: { isCheckboxItem(stripCR(lines[$0])) })
        if var item = anchor {
            // Keep the item's nested lines (sub-bullets, wrapped text) with it.
            while item + 1 < end, !isBlank(item + 1), lines[item + 1].first.map({ $0 == " " || $0 == "\t" }) == true {
                item += 1
            }
            anchor = item
        } else {
            anchor = body.last(where: { !isBlank($0) })
        }
        if let anchor {
            let lineEnding = lines[anchor].hasSuffix("\r") ? "\r" : ""
            lines.insert(rendered + lineEnding, at: anchor + 1)
        } else {
            var insertion = ["", rendered]
            if body.isEmpty && end < lines.endIndex { insertion.append("") }
            lines.insert(contentsOf: insertion, at: start + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Gives every task line under `## Action Items` that lacks a valid
    /// `casablanca-todo` id a fresh one, editing only those lines. Returns the
    /// (possibly unchanged) markdown and the tasks, all with ids, in file order.
    static func assigningMissingTaskIDs(_ markdown: String) -> (markdown: String, tasks: [TaskLine]) {
        var lines = markdown.components(separatedBy: "\n")
        var tasks: [TaskLine] = []
        for (index, task) in actionItemTaskLineIndices(in: lines) {
            guard task.id == nil else {
                tasks.append(task)
                continue
            }
            let assigned = task.withID(UUID())
            let lineEnding = lines[index].hasSuffix("\r") ? "\r" : ""
            let content = stripCR(lines[index])
            if content.range(of: "<!-- casablanca-todo:", options: .caseInsensitive) == nil {
                lines[index] = "\(content) <!-- casablanca-todo: \(assigned.id!.uuidString.uppercased()) -->\(lineEnding)"
            } else {
                // A malformed id comment: re-render this one line.
                lines[index] = render([assigned]) + lineEnding
            }
            tasks.append(assigned)
        }
        return (lines.joined(separator: "\n"), tasks)
    }

    private static func actionItemsHeadingIndex(in lines: [String]) -> Int? {
        lines.firstIndex { stripCR($0).trimmingCharacters(in: .whitespaces) == "## Action Items" }
    }

    /// Same boundary as `section(named:from:)`.
    private static func sectionEnd(in lines: [String], after start: Int) -> Int {
        lines[(start + 1)...].firstIndex(where: isSectionBoundary) ?? lines.endIndex
    }

    /// A `# ` or `## ` heading closes a `## ` section; `###` and deeper are
    /// sub-headings that stay inside it.
    private static func isSectionBoundary(_ line: String) -> Bool {
        line.hasPrefix("## ") || line.hasPrefix("# ")
    }

    /// A top-level checkbox list item in any marker/state (`- [ ]`, `* [x]`,
    /// `+ [/]`, ...) — wider than `taskExpression`, used only for placement.
    private static func isCheckboxItem(_ line: String) -> Bool {
        let characters = Array(line.prefix(6))
        return characters.count == 6
            && "-*+".contains(characters[0])
            && characters[1] == " " && characters[2] == "[" && characters[4] == "]" && characters[5] == " "
    }

    /// The task lines `parseMeetingActionItems` recognizes, with their indices.
    private static func actionItemTaskLineIndices(in lines: [String]) -> [(index: Int, task: TaskLine)] {
        guard let start = actionItemsHeadingIndex(in: lines) else { return [] }
        return ((start + 1)..<sectionEnd(in: lines, after: start)).compactMap { index in
            parseTaskLine(stripCR(lines[index])).map { (index, $0) }
        }
    }

    private static func stripCR(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    static func tasksAssigningIDsIfNeeded(_ tasks: [TaskLine]) -> [TaskLine] {
        tasks.map { task in
            task.id == nil ? task.withID(UUID()) : task
        }
    }

    private static func parseTasks(in body: String) -> [TaskLine] {
        body
            .components(separatedBy: .newlines)
            .compactMap(parseTaskLine)
    }

    private static func parseTaskLine(_ line: String) -> TaskLine? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = taskExpression.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        let completedMarker = nsLine.substring(with: match.range(at: 1))
        let fullText = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        let split = splittingSuffix(fullText)

        let id: UUID?
        let idRange = match.range(at: 3)
        if idRange.location != NSNotFound {
            id = UUID(uuidString: nsLine.substring(with: idRange))
        } else {
            id = nil
        }

        return TaskLine(
            id: id,
            text: split.text,
            isCompleted: completedMarker.lowercased() == "x",
            owner: split.owner,
            due: split.due,
            timestamp: split.timestamp
        )
    }

    private static func render(_ tasks: [TaskLine]) -> String {
        guard !tasks.isEmpty else {
            return ""
        }

        return tasks
            .map { task in
                let marker = task.isCompleted ? "x" : " "
                let body = task.text + suffix(owner: task.owner, due: task.due, timestamp: task.timestamp)
                if let id = task.id {
                    return "- [\(marker)] \(body) <!-- casablanca-todo: \(id.uuidString.uppercased()) -->"
                }
                return "- [\(marker)] \(body)"
            }
            .joined(separator: "\n")
    }

    private static func meetingSectionLines(tasks: [TaskLine]) -> [String] {
        let renderedTasks = render(tasks)
        var lines = ["## Action Items", ""]
        if !renderedTasks.isEmpty {
            lines.append(contentsOf: renderedTasks.components(separatedBy: .newlines))
        }
        return lines
    }

    private static func section(named title: String, from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        let header = "## \(title)"

        guard let startIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            return ""
        }

        var collected: [String] = []
        for line in lines[(startIndex + 1)...] {
            if isSectionBoundary(line) {
                break
            }
            collected.append(line)
        }

        return collected.joined(separator: "\n")
    }
}
