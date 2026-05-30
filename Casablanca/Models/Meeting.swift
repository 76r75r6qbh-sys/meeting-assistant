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

struct TimestampedNote: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: TimeInterval
    let text: String
    let createdAt: Date

    init(timestamp: TimeInterval, text: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.text = text
        self.createdAt = Date()
    }

    var formattedTimestamp: String {
        let totalSeconds = Int(timestamp)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
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
    var timestampedNotes: [TimestampedNote] = []
    var transcript: String?
    var rawTranscript: String?
    var summary: String?
    var recordingFileURL: String?
    var recordingDuration: Double?
    var transcriptionLanguage: String = "en-US"
    var appleNotesSummaryNoteID: String?
    var appleNotesRawNotesNoteID: String?
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
        self.timestampedNotes = []
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
}
