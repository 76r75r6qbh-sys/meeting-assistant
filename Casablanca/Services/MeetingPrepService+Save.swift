import Foundation

/// Load/save pair for the prep editor that remembers WHERE the prep was loaded
/// from and WHAT it looked like, so a save goes back to that same file and does
/// not clobber to-dos written to it while the editor was open (by
/// summarization, a Claude skill, or the app's own todo list).
///
/// Merge strategy on save, when the file changed on disk since it was loaded:
/// the editor's text wins, except for `## Action Items` task lines —
/// - a task that is on disk now, was not there at load, and is not in the
///   editor's text was added meanwhile, so it is appended to the saved text;
/// - a task whose checkbox changed on disk since load, and that the editor left
///   as it was at load, takes the on-disk state.
/// A task the user deleted in the editor (there at load, gone from the buffer)
/// stays deleted. Non-task edits made on disk meanwhile are not merged.
/// Tasks are matched by their `casablanca-todo` id, or by text when they have
/// none.
extension MeetingPrepService {
    struct LoadedPrep: Equatable {
        /// The markdown as read from disk (or the meeting's local notes).
        let markdown: String
        /// The vault file it was read from; nil when it did not come from one.
        let sourceURL: URL?
    }

    /// Like `loadPrepMarkdown`, but also returns the candidate file the text
    /// came from. Falls back to `meeting.localPrepNotes` (no source URL).
    static func loadPrep(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> LoadedPrep? {
        if AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian,
           let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) {
            for url in files.prepCandidates {
                guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return LoadedPrep(markdown: markdown, sourceURL: url)
                }
            }
        }
        guard !meeting.localPrepNotes.isEmpty else { return nil }
        return LoadedPrep(markdown: meeting.localPrepNotes, sourceURL: nil)
    }

    /// The outcome of a save: the text written, and what the editor should
    /// treat as loaded from now on (so the next save merges against it).
    struct SavedPrep: Equatable {
        let markdown: String
        let loaded: LoadedPrep
        /// Set when the editor's prep did not come from the vault but a vault
        /// prep file appeared meanwhile (a skill wrote one): the editor's text
        /// was appended to that file under `adoptedSeparator`, never over it.
        let adoptedVaultFile: URL?
    }

    /// Heads the editor's text when it is appended to a vault prep file the
    /// editor did not load (see `savePrepAndReload`).
    static let adoptedSeparator = "\n\n---\n\n<!-- Added from Casablanca's prep editor -->\n\n"

    /// Saves the editor's `markdown`. In Obsidian mode it writes back to the
    /// file it was loaded from (else the canonical Prep path), merging task
    /// lines changed on disk since `loaded` (see the type comment). Returns the
    /// text actually saved.
    @discardableResult
    static func savePrep(
        _ markdown: String,
        loaded: LoadedPrep?,
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> String {
        try savePrepAndReload(
            markdown, loaded: loaded, for: meeting, userDefaults: userDefaults, fileManager: fileManager
        ).markdown
    }

    /// `savePrep`, plus the state the editor should hold afterwards.
    ///
    /// Zero data loss when the editor's prep did not come from a vault file
    /// (`loaded` is nil or came from `localPrepNotes`) but one exists now — the
    /// meeting-brief skill writes `- Prep.md` while the app is open: that file
    /// is never overwritten. If it has prose, the editor's text is appended
    /// after `adoptedSeparator` (skipped when empty or already contained), the
    /// editor's text is also kept in `localPrepNotes`, and the vault file
    /// becomes the editor's source from then on.
    static func savePrepAndReload(
        _ markdown: String,
        loaded: LoadedPrep?,
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> SavedPrep {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian,
              let url = loaded?.sourceURL
                ?? existingVaultPrepURL(for: meeting, userDefaults: userDefaults)
                ?? prepURL(for: meeting, userDefaults: userDefaults) else {
            meeting.localPrepNotes = markdown
            return SavedPrep(markdown: markdown, loaded: LoadedPrep(markdown: markdown, sourceURL: nil), adoptedVaultFile: nil)
        }

        var output = markdown
        var adopted: URL?
        if fileManager.fileExists(atPath: url.path) {
            // Never treat an unreadable file as empty: that would overwrite it.
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            let hasDiskProse = !onDisk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if loaded?.sourceURL == nil, hasDiskProse {
                // Not the file the editor loaded: keep it whole, add ours below.
                meeting.localPrepNotes = markdown
                output = appendingEditorText(markdown, to: onDisk)
                adopted = url
                Log.export.notice(
                    "Prep save: a vault prep file appeared since the editor loaded; appended instead of overwriting \(url.lastPathComponent, privacy: .public)"
                )
            } else {
                let baseline = loaded?.sourceURL == nil ? "" : (loaded?.markdown ?? "")
                if onDisk != baseline {
                    output = mergingDiskTasks(into: markdown, onDisk: onDisk, baseline: baseline)
                }
            }
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
        return SavedPrep(markdown: output, loaded: LoadedPrep(markdown: output, sourceURL: url), adoptedVaultFile: adopted)
    }

    /// The first non-empty prep candidate already in the vault — the file
    /// `loadPrep` would read now.
    private static func existingVaultPrepURL(for meeting: Meeting, userDefaults: UserDefaults) -> URL? {
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) else { return nil }
        return files.prepCandidates.first { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func appendingEditorText(_ editorText: String, to onDisk: String) -> String {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !onDisk.contains(trimmed) else { return onDisk }
        let base = onDisk.hasSuffix("\n") ? String(onDisk.dropLast()) : onDisk
        return base + adoptedSeparator + trimmed + "\n"
    }

    /// Pure merge step of `savePrep`; exposed for tests.
    static func mergingDiskTasks(into buffer: String, onDisk: String, baseline: String) -> String {
        typealias Line = ObsidianTodoMarkdown.TaskLine
        func key(_ task: Line) -> String { task.id.map { "id:\($0.uuidString)" } ?? "text:\(task.text)" }
        func byKey(_ tasks: [Line]) -> [String: Line] {
            Dictionary(tasks.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        }

        let baselineTasks = byKey(ObsidianTodoMarkdown.parseMeetingActionItems(baseline))
        let bufferTasks = byKey(ObsidianTodoMarkdown.parseMeetingActionItems(buffer))
        var merged = buffer

        for diskTask in ObsidianTodoMarkdown.parseMeetingActionItems(onDisk) {
            let taskKey = key(diskTask)
            if let bufferTask = bufferTasks[taskKey] {
                // Toggled on disk while the editor left it untouched.
                if let id = diskTask.id,
                   let atLoad = baselineTasks[taskKey],
                   atLoad.isCompleted != diskTask.isCompleted,
                   bufferTask.isCompleted == atLoad.isCompleted,
                   let toggled = ObsidianTodoMarkdown.settingTaskCompletion(merged, id: id, isCompleted: diskTask.isCompleted) {
                    merged = toggled
                }
            } else if baselineTasks[taskKey] == nil {
                // Added on disk since load and not in the editor: keep it.
                merged = ObsidianTodoMarkdown.appendingTask(merged, diskTask)
            }
        }
        return merged
    }
}
