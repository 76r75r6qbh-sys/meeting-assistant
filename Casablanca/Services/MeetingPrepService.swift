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
        readPrepMarkdown(from: prepSource(for: meeting, userDefaults: userDefaults).candidateURLs)
    }

    // MARK: - Resolved prep (vault file or local notes)

    /// Plain-data snapshot of everywhere a meeting's prep can live. Captured on
    /// the caller's actor (it reads the SwiftData model) so the file read can
    /// then run on any thread.
    struct PrepSource: Sendable, Equatable {
        /// Vault prep files to try, in order. Empty unless prep storage is
        /// Obsidian and a vault is configured.
        let candidateURLs: [URL]
        /// `meeting.localPrepNotes` — where `writePrep` puts prep when there is
        /// no vault file to write (local storage, or no vault configured).
        let localNotes: String
    }

    static func prepSource(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) -> PrepSource {
        var candidateURLs: [URL] = []
        if AppPreferences.prepTodoStorage(in: userDefaults) == .obsidian,
           let files = ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: userDefaults) {
            candidateURLs = files.prepCandidates
        }
        return PrepSource(candidateURLs: candidateURLs, localNotes: meeting.localPrepNotes)
    }

    /// The first candidate file with non-whitespace content. Synchronous file
    /// I/O — keep it off the main thread where possible.
    static func readPrepMarkdown(from candidateURLs: [URL]) -> String? {
        for prepURL in candidateURLs {
            guard let markdown = try? String(contentsOf: prepURL, encoding: .utf8) else { continue }
            if hasPrepContent(markdown) { return markdown }
        }
        return nil
    }

    /// The prep to show for a meeting: the vault prep file when one has
    /// content, otherwise non-blank local prep notes — the same precedence
    /// `PrepEditorView` uses when it opens a meeting's prep.
    static func resolvedPrepMarkdown(from source: PrepSource) -> String? {
        if let markdown = readPrepMarkdown(from: source.candidateURLs) { return markdown }
        return hasPrepContent(source.localNotes) ? source.localNotes : nil
    }

    /// Whether `source` holds any prep worth showing (whitespace-only content
    /// counts as none). Reads files.
    static func hasPrepContent(_ source: PrepSource) -> Bool {
        resolvedPrepMarkdown(from: source) != nil
    }

    static func hasPrepContent(_ markdown: String?) -> Bool {
        !(markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// `resolvedPrepMarkdown` with the vault read moved off the main actor.
    /// The model is only touched here, on the main actor; the detached task
    /// gets the Sendable snapshot.
    @MainActor
    static func loadResolvedPrepMarkdown(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard
    ) async -> String? {
        let source = prepSource(for: meeting, userDefaults: userDefaults)
        return await Task.detached(priority: .userInitiated) {
            resolvedPrepMarkdown(from: source)
        }.value
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
