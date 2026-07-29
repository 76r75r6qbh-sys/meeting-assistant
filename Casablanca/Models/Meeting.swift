import Foundation
import SwiftData

enum AppPreferenceKey {
    static let obsidianVaultPath = "obsidianVaultPath"
    static let ollamaEndpoint = "ollamaEndpoint"
    static let ollamaModel = "ollamaModel"
    static let llmProvider = "llmProvider"
    static let omlxEndpoint = "omlxEndpoint"
    static let omlxModel = "omlxModel"
    static let omlxAPIKey = "omlxAPIKey"
    /// Path to the `claude` binary. Empty means "auto-detect"; `ClaudeCLIProvider`
    /// writes the path it detected back here so Settings can show it.
    static let claudeCLIPath = "claudeCLIPath"
    static let claudeCLIModel = "claudeCLIModel"
    static let whisperModel = "whisperModel"
    static let defaultTranscriptionLanguage = "defaultTranscriptionLanguage"
    static let summaryPromptTemplate = "summaryPromptTemplate"
    static let autoExportEnabled = "autoExportEnabled"
    static let legacyAutoExportNotesToObsidian = "autoExportNotesToObsidian"
    @available(*, deprecated, message: "Use autoExportEnabled. This alias exists only until Task 9 of the apple-notes-export plan migrates the remaining call sites.")
    static let autoExportNotesToObsidian = "autoExportNotesToObsidian"
    static let autoSummarizeAfterTranscription = "autoSummarizeAfterTranscription"
    static let defaultRecordingInputDeviceID = "defaultRecordingInputDeviceID"
    static let recordingWorkspaceFocusMode = "recordingWorkspaceFocusMode"
    static let terminologyCorrectionEnabled = "terminologyCorrectionEnabled"
    static let terminologyList = "terminologyList"
    static let exportDestination = "exportDestination"
    static let prepTodoStorage = "prepTodoStorage"
    static let actionQueuePath = "actionQueuePath"
    static let prepInspectorWidth = "prepInspectorWidth"
    static let detailInspectorWidth = "detailInspectorWidth"
    static let notesTextSize = "notesTextSize"
    static let notesReadingWidth = "notesReadingWidth"
    static let notesTodosExpanded = "notesTodosExpanded"
    static let summaryThinkingEnabled = "summaryThinkingEnabled"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let keepOriginalWAV = "keepOriginalWAV"
    static let useNativeMarkdownEditor = "useNativeMarkdownEditor"
    static let meetingStartNotificationsEnabled = "meetingStartNotificationsEnabled"
    static let meetingStartNotificationLeadTime = "meetingStartNotificationLeadTime"
}

enum AppPreferenceValue {
    static let systemDefaultRecordingInputDevice = "system-default"
    static let defaultWhisperModel = "openai_whisper-base"
}

enum MeetingStatus: String, Codable {
    case upcoming
    case notesOnly
    case recording
    case pausedRecording
    case processing
    case completed
}

enum MeetingDetailPresentation: Equatable {
    case workspace
    case processing
    case completed
}

extension MeetingStatus {
    var detailPresentation: MeetingDetailPresentation {
        switch self {
        case .upcoming, .notesOnly, .recording, .pausedRecording:
            return .workspace
        case .processing:
            return .processing
        case .completed:
            return .completed
        }
    }
}

@Model
final class Meeting {
    var id: UUID
    var title: String
    var date: Date
    var endDate: Date?
    var calendarEventID: String?
    var participants: [String]
    var status: MeetingStatus
    var userNotes: String
    // NOTE (Phase 3a spike, macOS 14/15): do NOT add @Attribute(.externalStorage)
    // to `transcript` / `rawTranscript`. The spike (ExternalStorageSpikeTests)
    // proved it is a silent NO-OP on String/String? — saving a ~4 MB transcript
    // produced ZERO files in the store's _EXTERNAL_DATA directory; the value
    // stays inline in the row. `.externalStorage` only externalizes `Data`.
    // It round-trips fine, but adds migration risk for no benefit, so it was
    // dropped. The real fix for large-transcript memory/IO pressure is Phase 3b's
    // `propertiesToFetch` (fetch metadata without hydrating these large columns).
    var transcript: String?
    var rawTranscript: String?
    var summary: String?
    var recordingFileURL: String?
    var recordingDuration: Double?
    var transcriptionLanguage: String = "en-US"
    /// Project/grouping labels. Stored NORMALIZED (lowercased, trimmed, deduped,
    /// no empties) via ``Meeting/normalizeTags(_:)`` so add + filter + search can't
    /// drift. Default `[]` keeps this an additive, lightweight SwiftData migration.
    /// NOTE: this is a Codable array blob — `#Predicate` CANNOT query it; all tag
    /// filtering/search must run IN MEMORY (proven in Phase 3).
    var tags: [String] = []
    var appleNotesSummaryNoteID: String?
    var appleNotesRawNotesNoteID: String?
    var localPrepNotes: String = ""
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \TodoItem.meeting) var todos: [TodoItem] = []

    init(
        title: String,
        date: Date,
        endDate: Date? = nil,
        calendarEventID: String? = nil,
        participants: [String] = [],
        status: MeetingStatus = .upcoming
    ) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.endDate = endDate
        self.calendarEventID = calendarEventID
        self.participants = participants
        self.status = status
        self.userNotes = ""
        self.transcriptionLanguage = UserDefaults.standard.string(forKey: AppPreferenceKey.defaultTranscriptionLanguage) ?? "en-US"
        self.createdAt = Date()
        self.todos = []
    }

    var isUpcoming: Bool {
        date > Date() && status == .upcoming
    }

    var isPast: Bool {
        guard let endDate else { return date < Date() }
        return endDate < Date()
    }

    var duration: TimeInterval? {
        guard let endDate else { return nil }
        return endDate.timeIntervalSince(date)
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: date)
        if let endDate {
            let end = formatter.string(from: endDate)
            return "\(start) - \(end)"
        }
        return start
    }

    var formattedDuration: String? {
        guard let duration else { return nil }
        let minutes = Int(duration / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let remaining = minutes % 60
            return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    var obsidianFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        return "\(dateStr) \(sanitizedTitle)"
    }

    var sanitizedTitle: String {
        title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
    }

    var recordingDisplayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "\(formatter.string(from: date)) \(sanitizedTitle)"
    }

    // MARK: - Occurrence date normalization

    /// Canonical form of a recurring-event occurrence start used as the
    /// disambiguation key in ``MeetingListViewModel/findOrCreateMeeting``.
    ///
    /// EventKit can hand back an `EKEvent.startDate` for the SAME occurrence that
    /// differs by a sub-second amount between two fetches. The match path uses an
    /// exact `Date ==` in a `#Predicate`, so an un-normalized jittered start would
    /// miss the existing row and create a DUPLICATE meeting (re-introducing the
    /// notes/transcript collision in reverse). We therefore round the start to the
    /// nearest WHOLE SECOND at BOTH the create and the match path, so two `Date`s
    /// with identical wall-clock-to-the-second compare equal.
    ///
    /// Rounding (`.rounded()`, i.e. round-half-to-even at the second boundary) is
    /// chosen over flooring purely so the collapse is symmetric around the true
    /// instant — flooring would also work; the only invariant that matters is that
    /// both paths apply the SAME transform. Second granularity is invisible to
    /// users (all display formatters are `HH:mm` / `yyyy-MM-dd`) and to series
    /// ordering (`MeetingSeriesResolver` orders by `<`/`>` and real occurrences are
    /// minutes-to-days apart), so nothing user-facing depends on sub-second
    /// precision.
    static func normalizedOccurrenceDate(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded())
    }

    // MARK: - Tags

    /// The single source of truth for how a raw tag string becomes its canonical
    /// stored form: lowercased + whitespace-trimmed. Returns `nil` for empties so
    /// callers can drop them. Used by BOTH the editor (when adding) and the
    /// filter/search (when comparing) so the two can never diverge.
    static func normalizeTag(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Normalize a collection of raw tags: trim + lowercase each, drop empties,
    /// and dedupe while preserving first-seen order.
    static func normalizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            guard let tag = normalizeTag(value) else { continue }
            if seen.insert(tag).inserted {
                out.append(tag)
            }
        }
        return out
    }

    /// Set `tags` to the normalized form of `raw`. Convenience so call sites don't
    /// forget to normalize before assigning.
    func setTags(_ raw: [String]) {
        tags = Meeting.normalizeTags(raw)
    }

    /// Add a single raw tag (normalized) if not already present. Returns true if
    /// it was added.
    @discardableResult
    func addTag(_ raw: String) -> Bool {
        guard let tag = Meeting.normalizeTag(raw) else { return false }
        guard !tags.contains(tag) else { return false }
        tags.append(tag)
        return true
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }
}
