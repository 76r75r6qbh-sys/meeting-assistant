import Foundation

enum MeetingPrepService {
    static func prepURL(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return nil }
        return ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults)?.prepURL
    }

    static func loadPrepMarkdown(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return nil }
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) else {
            return nil
        }

        for prepURL in files.prepCandidates {
            guard let markdown = try? String(contentsOf: prepURL, encoding: .utf8) else { continue }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return markdown }
        }
        return nil
    }

    static func writePrep(
        _ markdown: String,
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) throws {
        if AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian,
           let url = prepURL(for: meeting, userDefaults: userDefaults) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } else {
            meeting.localPrepNotes = markdown
        }
    }

    static func hasPrep(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        guard AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian else { return false }
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) else {
            return false
        }
        return files.prepCandidates.contains { fileManager.fileExists(atPath: $0.path) }
    }
}
