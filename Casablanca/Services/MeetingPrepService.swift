import Foundation

enum MeetingPrepService {
    static func prepURL(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults)?.prepURL
    }

    static func loadPrepMarkdown(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) else {
            return nil
        }

        for prepURL in files.prepCandidates {
            guard let markdown = try? String(contentsOf: prepURL, encoding: .utf8) else {
                continue
            }

            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return markdown
            }
        }

        return nil
    }

    static func hasPrep(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) else {
            return false
        }

        return files.prepCandidates.contains { fileManager.fileExists(atPath: $0.path) }
    }
}
