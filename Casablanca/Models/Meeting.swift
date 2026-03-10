import Foundation
import SwiftData

enum MeetingStatus: String, Codable {
    case upcoming
    case notesOnly
    case recording
    case processing
    case completed
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
    var transcript: String?
    var summary: String?
    var recordingFileURL: String?
    var createdAt: Date

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
        self.createdAt = Date()
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
        let sanitizedTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return "\(dateStr) \(sanitizedTitle)"
    }
}
