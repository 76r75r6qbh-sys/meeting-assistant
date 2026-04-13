import Foundation

enum ObsidianTodoMarkdown {
    struct TaskLine: Equatable {
        let id: UUID?
        let text: String
        let isCompleted: Bool
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

    static func renderMeetingDocument(_ markdown: String, actionItems: [TaskLine]) -> String {
        let replacementLines = meetingSectionLines(tasks: actionItems)
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
        for index in lines.index(after: startIndex)..<lines.endIndex where lines[index].hasPrefix("## ") {
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

    static func tasksAssigningIDsIfNeeded(_ tasks: [TaskLine]) -> [TaskLine] {
        tasks.map { task in
            TaskLine(id: task.id ?? UUID(), text: task.text, isCompleted: task.isCompleted)
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
        let text = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

        let id: UUID?
        let idRange = match.range(at: 3)
        if idRange.location != NSNotFound {
            id = UUID(uuidString: nsLine.substring(with: idRange))
        } else {
            id = nil
        }

        return TaskLine(
            id: id,
            text: text,
            isCompleted: completedMarker.lowercased() == "x"
        )
    }

    private static func render(_ tasks: [TaskLine]) -> String {
        guard !tasks.isEmpty else {
            return ""
        }

        return tasks
            .map { task in
                let marker = task.isCompleted ? "x" : " "
                if let id = task.id {
                    return "- [\(marker)] \(task.text) <!-- casablanca-todo: \(id.uuidString.uppercased()) -->"
                }
                return "- [\(marker)] \(task.text)"
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
            if line.hasPrefix("## ") {
                break
            }
            collected.append(line)
        }

        return collected.joined(separator: "\n")
    }
}
