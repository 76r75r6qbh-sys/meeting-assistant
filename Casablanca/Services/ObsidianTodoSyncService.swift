import Foundation
import SwiftData

@MainActor
enum ObsidianTodoSyncService {
    static func refreshAllTodos(
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try bootstrapLegacyGenericTodos(in: modelContext, userDefaults: userDefaults, fileManager: fileManager)
        try syncGenericTodos(in: modelContext, userDefaults: userDefaults, fileManager: fileManager)

        let meetings = try modelContext.fetch(FetchDescriptor<Meeting>())
        for meeting in meetings {
            try refreshTodos(for: meeting, in: modelContext, userDefaults: userDefaults, fileManager: fileManager)
        }
    }

    static func refreshTodos(
        for meeting: Meeting,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults, fileManager: fileManager) else {
            return
        }

        try fileManager.createDirectory(at: files.notesDirectory, withIntermediateDirectories: true)
        try bootstrapLegacyMeetingTodos(
            for: meeting,
            files: files,
            in: modelContext,
            fileManager: fileManager
        )

        let syncedTasks = try syncMeetingFiles(
            files,
            meeting: meeting,
            in: modelContext,
            fileManager: fileManager
        )
        try removeMissingMeetingRows(
            for: meeting,
            sourcePaths: Set(syncedTasks.map(\.sourceFilePath)),
            importedIDs: Set(syncedTasks.map(\.id)),
            in: modelContext
        )
        try modelContext.save()
    }

    static func createGenericTodo(
        text: String,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let genericURL = try genericTodosURL(userDefaults: userDefaults)
        try ensureParentDirectory(for: genericURL, fileManager: fileManager)

        var document = try loadGenericDocument(from: genericURL)
        let task = ObsidianTodoMarkdown.TaskLine(id: UUID(), text: trimmed, isCompleted: false)
        document.openTasks.append(task)
        try write(document: document, to: genericURL)

        try upsertTask(
            task,
            meeting: nil,
            sourceFilePath: genericURL.path,
            in: modelContext
        )
        try modelContext.save()
    }

    static func createMeetingTodo(
        text: String,
        meeting: Meeting,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults, fileManager: fileManager) else {
            return
        }

        try ensureParentDirectory(for: files.canonicalTodoWriteURL, fileManager: fileManager)
        let markdown = (try? String(contentsOf: files.canonicalTodoWriteURL, encoding: .utf8)) ?? ""
        var tasks = ObsidianTodoMarkdown.tasksAssigningIDsIfNeeded(
            ObsidianTodoMarkdown.parseMeetingActionItems(markdown)
        )
        let task = ObsidianTodoMarkdown.TaskLine(id: UUID(), text: trimmed, isCompleted: false)
        tasks.append(task)

        let updatedMarkdown = ObsidianTodoMarkdown.renderMeetingDocument(markdown, actionItems: tasks)
        try updatedMarkdown.write(to: files.canonicalTodoWriteURL, atomically: true, encoding: .utf8)

        try upsertTask(
            task,
            meeting: meeting,
            sourceFilePath: files.canonicalTodoWriteURL.path,
            in: modelContext
        )
        try modelContext.save()
    }

    static func setCompleted(
        _ isCompleted: Bool,
        for todo: TodoItem,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard let sourceFilePath = todo.sourceFilePath else { return }
        let sourceURL = URL(fileURLWithPath: sourceFilePath)

        if todo.meeting == nil {
            var document = try loadGenericDocument(from: sourceURL)
            document.openTasks = document.openTasks.filter { $0.id != todo.id }
            document.doneTasks = document.doneTasks.filter { $0.id != todo.id }
            let updatedTask = ObsidianTodoMarkdown.TaskLine(id: todo.id, text: todo.text, isCompleted: isCompleted)
            if isCompleted {
                document.doneTasks.append(updatedTask)
            } else {
                document.openTasks.append(updatedTask)
            }
            try write(document: document, to: sourceURL)
        } else {
            let markdown = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
            var tasks = ObsidianTodoMarkdown.tasksAssigningIDsIfNeeded(
                ObsidianTodoMarkdown.parseMeetingActionItems(markdown)
            )
            if let index = tasks.firstIndex(where: { $0.id == todo.id }) {
                tasks[index] = ObsidianTodoMarkdown.TaskLine(id: todo.id, text: todo.text, isCompleted: isCompleted)
                let updatedMarkdown = ObsidianTodoMarkdown.renderMeetingDocument(markdown, actionItems: tasks)
                try updatedMarkdown.write(to: sourceURL, atomically: true, encoding: .utf8)
            }
        }

        todo.isCompleted = isCompleted
        try modelContext.save()
    }

    static func deleteTodo(
        _ todo: TodoItem,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard let sourceFilePath = todo.sourceFilePath else {
            modelContext.delete(todo)
            try modelContext.save()
            return
        }

        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        if todo.meeting == nil {
            var document = try loadGenericDocument(from: sourceURL)
            document.openTasks.removeAll { $0.id == todo.id }
            document.doneTasks.removeAll { $0.id == todo.id }
            try write(document: document, to: sourceURL)
        } else {
            let markdown = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
            var tasks = ObsidianTodoMarkdown.tasksAssigningIDsIfNeeded(
                ObsidianTodoMarkdown.parseMeetingActionItems(markdown)
            )
            tasks.removeAll { $0.id == todo.id }
            let updatedMarkdown = ObsidianTodoMarkdown.renderMeetingDocument(markdown, actionItems: tasks)
            try updatedMarkdown.write(to: sourceURL, atomically: true, encoding: .utf8)
        }

        modelContext.delete(todo)
        try modelContext.save()
    }

    private struct SyncedTask {
        let id: UUID
        let sourceFilePath: String
    }

    private static func bootstrapLegacyGenericTodos(
        in modelContext: ModelContext,
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) throws {
        let legacyTodos = try modelContext.fetch(FetchDescriptor<TodoItem>())
            .filter { $0.meeting == nil && $0.sourceFilePath == nil }
        guard !legacyTodos.isEmpty else { return }

        let genericURL = try genericTodosURL(userDefaults: userDefaults)
        try ensureParentDirectory(for: genericURL, fileManager: fileManager)
        var document = try loadGenericDocument(from: genericURL)

        for todo in legacyTodos {
            let task = ObsidianTodoMarkdown.TaskLine(id: todo.id, text: todo.text, isCompleted: todo.isCompleted)
            if todo.isCompleted {
                if !document.doneTasks.contains(where: { $0.id == todo.id }) {
                    document.doneTasks.append(task)
                }
            } else if !document.openTasks.contains(where: { $0.id == todo.id }) {
                document.openTasks.append(task)
            }
            todo.sourceFilePath = genericURL.path
        }

        try write(document: document, to: genericURL)
        try modelContext.save()
    }

    private static func bootstrapLegacyMeetingTodos(
        for meeting: Meeting,
        files: ObsidianMeetingFiles.MeetingFiles,
        in modelContext: ModelContext,
        fileManager: FileManager
    ) throws {
        let legacyTodos = meeting.todos.filter { $0.sourceFilePath == nil }
        guard !legacyTodos.isEmpty else { return }

        try ensureParentDirectory(for: files.canonicalTodoWriteURL, fileManager: fileManager)
        let markdown = (try? String(contentsOf: files.canonicalTodoWriteURL, encoding: .utf8)) ?? ""
        var tasks = ObsidianTodoMarkdown.tasksAssigningIDsIfNeeded(
            ObsidianTodoMarkdown.parseMeetingActionItems(markdown)
        )

        for todo in legacyTodos where !tasks.contains(where: { $0.id == todo.id }) {
            tasks.append(
                ObsidianTodoMarkdown.TaskLine(
                    id: todo.id,
                    text: todo.text,
                    isCompleted: todo.isCompleted
                )
            )
            todo.sourceFilePath = files.canonicalTodoWriteURL.path
        }

        let updatedMarkdown = ObsidianTodoMarkdown.renderMeetingDocument(markdown, actionItems: tasks)
        try updatedMarkdown.write(to: files.canonicalTodoWriteURL, atomically: true, encoding: .utf8)
        try modelContext.save()
    }

    @discardableResult
    private static func syncGenericTodos(
        in modelContext: ModelContext,
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) throws -> [SyncedTask] {
        let genericURL = try genericTodosURL(userDefaults: userDefaults)
        try ensureParentDirectory(for: genericURL, fileManager: fileManager)

        var document = try loadGenericDocument(from: genericURL)
        let assignedOpen = ObsidianTodoMarkdown.tasksAssigningIDsIfNeeded(document.openTasks)
        let assignedDone = ObsidianTodoMarkdown.tasksAssigningIDsIfNeeded(document.doneTasks)

        if assignedOpen != document.openTasks || assignedDone != document.doneTasks {
            document = .init(openTasks: assignedOpen, doneTasks: assignedDone)
            try write(document: document, to: genericURL)
        }

        let tasks = assignedOpen + assignedDone
        for task in tasks {
            try upsertTask(task, meeting: nil, sourceFilePath: genericURL.path, in: modelContext)
        }
        try removeMissingGenericRows(importedIDs: Set(tasks.compactMap(\.id)), sourceFilePath: genericURL.path, in: modelContext)
        try modelContext.save()

        return tasks.compactMap { task in
            guard let id = task.id else { return nil }
            return SyncedTask(id: id, sourceFilePath: genericURL.path)
        }
    }

    private static func syncMeetingFiles(
        _ files: ObsidianMeetingFiles.MeetingFiles,
        meeting: Meeting,
        in modelContext: ModelContext,
        fileManager: FileManager
    ) throws -> [SyncedTask] {
        var syncedTasks: [SyncedTask] = []

        let existingURLs = Array(
            Set(files.prepCandidates + files.notesCandidates)
        ).filter { fileManager.fileExists(atPath: $0.path) }

        for url in existingURLs {
            let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let parsedTasks = ObsidianTodoMarkdown.parseMeetingActionItems(markdown)
            let assignedTasks = ObsidianTodoMarkdown.tasksAssigningIDsIfNeeded(parsedTasks)

            if assignedTasks != parsedTasks {
                let updatedMarkdown = ObsidianTodoMarkdown.renderMeetingDocument(markdown, actionItems: assignedTasks)
                try updatedMarkdown.write(to: url, atomically: true, encoding: .utf8)
            }

            for task in assignedTasks {
                try upsertTask(task, meeting: meeting, sourceFilePath: url.path, in: modelContext)
                if let id = task.id {
                    syncedTasks.append(SyncedTask(id: id, sourceFilePath: url.path))
                }
            }
        }

        return syncedTasks
    }

    private static func upsertTask(
        _ task: ObsidianTodoMarkdown.TaskLine,
        meeting: Meeting?,
        sourceFilePath: String,
        in modelContext: ModelContext
    ) throws {
        guard let id = task.id else { return }

        let existingTodos = try modelContext.fetch(FetchDescriptor<TodoItem>())
        if let existing = existingTodos.first(where: { $0.id == id }) {
            existing.text = task.text
            existing.isCompleted = task.isCompleted
            existing.sourceFilePath = sourceFilePath
            existing.meeting = meeting
            return
        }

        let todo = TodoItem(
            id: id,
            text: task.text,
            isCompleted: task.isCompleted,
            sourceFilePath: sourceFilePath,
            meeting: meeting
        )
        modelContext.insert(todo)
    }

    private static func removeMissingGenericRows(
        importedIDs: Set<UUID>,
        sourceFilePath: String,
        in modelContext: ModelContext
    ) throws {
        let todos = try modelContext.fetch(FetchDescriptor<TodoItem>())
        for todo in todos where todo.meeting == nil && todo.sourceFilePath == sourceFilePath && !importedIDs.contains(todo.id) {
            modelContext.delete(todo)
        }
    }

    private static func removeMissingMeetingRows(
        for meeting: Meeting,
        sourcePaths: Set<String>,
        importedIDs: Set<UUID>,
        in modelContext: ModelContext
    ) throws {
        let todos = try modelContext.fetch(FetchDescriptor<TodoItem>())
        for todo in todos
        where todo.meeting?.id == meeting.id
            && (todo.sourceFilePath.map(sourcePaths.contains) ?? false)
            && !importedIDs.contains(todo.id) {
            modelContext.delete(todo)
        }
    }

    private static func loadGenericDocument(from url: URL) throws -> ObsidianTodoMarkdown.GenericDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let document = ObsidianTodoMarkdown.GenericDocument(openTasks: [], doneTasks: [])
            try write(document: document, to: url)
            return document
        }

        let markdown = try String(contentsOf: url, encoding: .utf8)
        return ObsidianTodoMarkdown.parseGenericDocument(markdown)
    }

    private static func write(document: ObsidianTodoMarkdown.GenericDocument, to url: URL) throws {
        let markdown = ObsidianTodoMarkdown.renderGenericDocument(
            openTasks: document.openTasks,
            doneTasks: document.doneTasks
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func ensureParentDirectory(for url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static func genericTodosURL(userDefaults: UserDefaults) throws -> URL {
        guard let url = ObsidianMeetingFiles.genericTodosURL(userDefaults: userDefaults) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}
