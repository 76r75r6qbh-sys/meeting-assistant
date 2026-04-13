import Foundation

struct ObsidianMeetingFiles {
    struct MeetingFiles {
        let notesDirectory: URL
        let prepURL: URL
        let notesURL: URL
        let prepCandidates: [URL]
        let notesCandidates: [URL]
        let canonicalTodoWriteURL: URL
    }

    static func meetingFiles(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> MeetingFiles? {
        guard let notesDirectory = meetingNotesDirectory(userDefaults: userDefaults) else {
            return nil
        }

        let exactBaseName = meeting.obsidianFileName
        let normalizedBaseName = normalizedBaseName(for: meeting)
        let prepCandidates = candidateURLs(
            directory: notesDirectory,
            exactBaseName: exactBaseName,
            normalizedBaseName: normalizedBaseName,
            suffix: "Prep"
        )
        let notesCandidates = candidateURLs(
            directory: notesDirectory,
            exactBaseName: exactBaseName,
            normalizedBaseName: normalizedBaseName,
            suffix: "Notes"
        )

        let canonicalTodoWriteURL =
            prepCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) ??
            notesCandidates[0]

        return MeetingFiles(
            notesDirectory: notesDirectory,
            prepURL: prepCandidates[0],
            notesURL: notesCandidates[0],
            prepCandidates: prepCandidates,
            notesCandidates: notesCandidates,
            canonicalTodoWriteURL: canonicalTodoWriteURL
        )
    }

    static func genericTodosURL(userDefaults: UserDefaults = .standard) -> URL? {
        guard let vaultRoot = vaultRoot(userDefaults: userDefaults) else {
            return nil
        }

        return vaultRoot
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("Casablanca Todos.md")
    }

    static func meetingNotesDirectory(userDefaults: UserDefaults = .standard) -> URL? {
        vaultRoot(userDefaults: userDefaults)?
            .appendingPathComponent("meeting notes", isDirectory: true)
    }

    private static func vaultRoot(userDefaults: UserDefaults) -> URL? {
        let vaultPath = userDefaults.string(forKey: AppPreferenceKey.obsidianVaultPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !vaultPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: vaultPath, isDirectory: true)
    }

    private static func candidateURLs(
        directory: URL,
        exactBaseName: String,
        normalizedBaseName: String,
        suffix: String
    ) -> [URL] {
        let exactFileName = "\(exactBaseName) - \(suffix).md"
        let normalizedFileName = "\(normalizedBaseName) - \(suffix).md"

        var urls = [directory.appendingPathComponent(exactFileName)]
        if normalizedFileName != exactFileName {
            urls.append(directory.appendingPathComponent(normalizedFileName))
        }
        return urls
    }

    private static func normalizedBaseName(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: meeting.date)
        return "\(dateString) \(meeting.title.normalizedObsidianPathComponent)"
    }
}

private extension String {
    var normalizedObsidianPathComponent: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
    }
}
