import Foundation
import SwiftData

@MainActor
enum ObsidianTodoSyncService {
    static func refreshAllTodos(
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return }
        try bootstrapLegacyGenericTodos(in: modelContext, userDefaults: userDefaults, fileManager: fileManager)
        // One fetch for the whole refresh: upserts look rows up by id here
        // instead of fetching every TodoItem per task.
        let index = try TodoIndex(modelContext)
        try syncGenericTodos(in: modelContext, index: index, userDefaults: userDefaults, fileManager: fileManager)

        // One unreadable or unwritable meeting file must not stop the others
        // from syncing: log it, carry on, and report the first failure at the end.
        var firstError: Error?
        let meetings = try modelContext.fetch(FetchDescriptor<Meeting>())
        for meeting in meetings {
            do {
                try refreshTodos(for: meeting, in: modelContext, index: index, userDefaults: userDefaults, fileManager: fileManager)
            } catch {
                Log.persistence.error(
                    "Todo sync failed for meeting \(meeting.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    static func refreshTodos(
        for meeting: Meeting,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return }
        try refreshTodos(
            for: meeting,
            in: modelContext,
            index: TodoIndex(modelContext),
            userDefaults: userDefaults,
            fileManager: fileManager
        )
    }

    private static func refreshTodos(
        for meeting: Meeting,
        in modelContext: ModelContext,
        index: TodoIndex,
        userDefaults: UserDefaults,
        fileManager: FileManager
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
            index: index,
            fileManager: fileManager
        )
        removeMissingMeetingRows(
            for: meeting,
            sourcePaths: Set(syncedTasks.map(\.sourceFilePath)),
            importedIDs: Set(syncedTasks.map(\.id)),
            in: modelContext,
            index: index
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

        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            let todo = TodoItem(text: trimmed, isCompleted: false, sourceFilePath: nil, meeting: nil)
            modelContext.insert(todo)
            try modelContext.save()
            return
        }

        let genericURL = try genericTodosURL(userDefaults: userDefaults)
        try ensureParentDirectory(for: genericURL, fileManager: fileManager)

        var document = try loadGenericDocument(from: genericURL)
        let task = ObsidianTodoMarkdown.TaskLine(id: UUID(), text: trimmed, isCompleted: false)
        document.openTasks.append(task)
        try write(document: document, to: genericURL)

        insertTodo(task, meeting: nil, sourceFilePath: genericURL.path, in: modelContext)
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

        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            let todo = TodoItem(text: trimmed, isCompleted: false, sourceFilePath: nil, meeting: meeting)
            modelContext.insert(todo)
            try modelContext.save()
            return
        }

        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults, fileManager: fileManager) else {
            return
        }

        try ensureParentDirectory(for: files.canonicalTodoWriteURL, fileManager: fileManager)
        let markdown = try readMarkdownIfPresent(at: files.canonicalTodoWriteURL, fileManager: fileManager)
        let task = ObsidianTodoMarkdown.TaskLine(id: UUID(), text: trimmed, isCompleted: false)

        let updatedMarkdown = ObsidianTodoMarkdown.appendingTask(markdown, task)
        try updatedMarkdown.write(to: files.canonicalTodoWriteURL, atomically: true, encoding: .utf8)

        insertTodo(task, meeting: meeting, sourceFilePath: files.canonicalTodoWriteURL.path, in: modelContext)
        try modelContext.save()
    }

    static func setCompleted(
        _ isCompleted: Bool,
        for todo: TodoItem,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            todo.isCompleted = isCompleted
            try modelContext.save()
            return
        }
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
            let markdown = try readMarkdownIfPresent(at: sourceURL, fileManager: fileManager)
            if let updatedMarkdown = ObsidianTodoMarkdown.settingTaskCompletion(markdown, id: todo.id, isCompleted: isCompleted) {
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
        if AppPreferences.prepTodoStorage(in: userDefaults) == .local {
            modelContext.delete(todo)
            try modelContext.save()
            return
        }
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
            let markdown = try readMarkdownIfPresent(at: sourceURL, fileManager: fileManager)
            if let updatedMarkdown = ObsidianTodoMarkdown.removingTask(markdown, id: todo.id) {
                try updatedMarkdown.write(to: sourceURL, atomically: true, encoding: .utf8)
            }
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
        let original = try readMarkdownIfPresent(at: files.canonicalTodoWriteURL, fileManager: fileManager)
        var markdown = original
        let existingIDs = Set(ObsidianTodoMarkdown.parseMeetingActionItems(markdown).compactMap(\.id))

        for todo in legacyTodos where !existingIDs.contains(todo.id) {
            markdown = ObsidianTodoMarkdown.appendingTask(
                markdown,
                ObsidianTodoMarkdown.TaskLine(
                    id: todo.id,
                    text: todo.text,
                    isCompleted: todo.isCompleted
                )
            )
        }
        // A legacy row whose id is already in the file is the same todo: it now
        // lives there too, so it is tracked against that file either way.
        for todo in legacyTodos {
            todo.sourceFilePath = files.canonicalTodoWriteURL.path
        }

        if markdown != original {
            try markdown.write(to: files.canonicalTodoWriteURL, atomically: true, encoding: .utf8)
        }
        try modelContext.save()
    }

    private static func syncGenericTodos(
        in modelContext: ModelContext,
        index: TodoIndex,
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) throws {
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
            upsertTask(task, meeting: nil, sourceFilePath: genericURL.path, in: modelContext, index: index)
        }
        removeMissingGenericRows(
            importedIDs: Set(tasks.compactMap(\.id)),
            sourceFilePath: genericURL.path,
            in: modelContext,
            index: index
        )
        try modelContext.save()
    }

    private static func syncMeetingFiles(
        _ files: ObsidianMeetingFiles.MeetingFiles,
        meeting: Meeting,
        in modelContext: ModelContext,
        index: TodoIndex,
        fileManager: FileManager
    ) throws -> [SyncedTask] {
        var syncedTasks: [SyncedTask] = []

        let existingURLs = Array(
            Set(files.prepCandidates + files.notesCandidates)
        ).filter { fileManager.fileExists(atPath: $0.path) }

        for url in existingURLs {
            let markdown = try readMarkdownIfPresent(at: url, fileManager: fileManager)
            let (updatedMarkdown, assignedTasks) = ObsidianTodoMarkdown.assigningMissingTaskIDs(markdown)

            if updatedMarkdown != markdown {
                try updatedMarkdown.write(to: url, atomically: true, encoding: .utf8)
            }

            for task in assignedTasks {
                upsertTask(task, meeting: meeting, sourceFilePath: url.path, in: modelContext, index: index)
                if let id = task.id {
                    syncedTasks.append(SyncedTask(id: id, sourceFilePath: url.path))
                }
            }
        }

        return syncedTasks
    }

    /// Every TodoItem keyed by id, fetched once per refresh and kept in step
    /// with the inserts and deletes the refresh makes.
    private final class TodoIndex {
        private(set) var byID: [UUID: TodoItem]

        init(_ modelContext: ModelContext) throws {
            let todos = try modelContext.fetch(FetchDescriptor<TodoItem>())
            byID = Dictionary(todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func insert(_ todo: TodoItem) { byID[todo.id] = todo }
        func remove(_ todo: TodoItem) { byID[todo.id] = nil }
    }

    private static func upsertTask(
        _ task: ObsidianTodoMarkdown.TaskLine,
        meeting: Meeting?,
        sourceFilePath: String,
        in modelContext: ModelContext,
        index: TodoIndex
    ) {
        guard let id = task.id else { return }

        if let existing = index.byID[id] {
            existing.text = task.text
            existing.isCompleted = task.isCompleted
            existing.sourceFilePath = sourceFilePath
            existing.meeting = meeting
            return
        }

        index.insert(insertTodo(task, meeting: meeting, sourceFilePath: sourceFilePath, in: modelContext))
    }

    /// Inserts a row for a task whose id is known to be new (just generated).
    @discardableResult
    private static func insertTodo(
        _ task: ObsidianTodoMarkdown.TaskLine,
        meeting: Meeting?,
        sourceFilePath: String,
        in modelContext: ModelContext
    ) -> TodoItem {
        let todo = TodoItem(
            id: task.id ?? UUID(),
            text: task.text,
            isCompleted: task.isCompleted,
            sourceFilePath: sourceFilePath,
            meeting: meeting
        )
        modelContext.insert(todo)
        return todo
    }

    private static func removeMissingGenericRows(
        importedIDs: Set<UUID>,
        sourceFilePath: String,
        in modelContext: ModelContext,
        index: TodoIndex
    ) {
        for todo in Array(index.byID.values)
        where todo.meeting == nil && todo.sourceFilePath == sourceFilePath && !importedIDs.contains(todo.id) {
            index.remove(todo)
            modelContext.delete(todo)
        }
    }

    private static func removeMissingMeetingRows(
        for meeting: Meeting,
        sourcePaths: Set<String>,
        importedIDs: Set<UUID>,
        in modelContext: ModelContext,
        index: TodoIndex
    ) {
        for todo in Array(index.byID.values)
        where todo.meeting?.id == meeting.id
            && (todo.sourceFilePath.map(sourcePaths.contains) ?? false)
            && !importedIDs.contains(todo.id) {
            index.remove(todo)
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

    /// Only a missing file reads as empty. Any other read failure (permissions,
    /// a non-UTF-8 file, an iCloud placeholder) throws so the caller does not
    /// go on to overwrite a file it could not read — mirrors
    /// `ObsidianMeetingExporter.preservingActionItems`.
    private static func readMarkdownIfPresent(at url: URL, fileManager: FileManager) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
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
