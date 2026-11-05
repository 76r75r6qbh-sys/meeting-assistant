// Casablanca/Models/TodoItem.swift
import Foundation
import SwiftData

@Model
final class TodoItem {
    var id: UUID
    var text: String
    var isCompleted: Bool
    var createdAt: Date
    var sourceFilePath: String?
    var meeting: Meeting?
    // Schema V3 — all optional or defaulted so the V2 → V3 migration is additive.
    var owner: String?
    var dueDate: Date?
    /// Transcript timestamp label of the source quote (`mm:ss` or `h:mm:ss`).
    var sourceTimestamp: String?
    var quote: String?
    /// Raw ``TodoStatus``; the default makes every pre-V3 to-do `.accepted`.
    var statusRaw: String = TodoStatus.accepted.rawValue
    /// Raw ``VerificationState``; `nil` for to-dos that were never verified.
    var verificationRaw: String?

    init(
        id: UUID = UUID(),
        text: String,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        sourceFilePath: String? = nil,
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.sourceFilePath = sourceFilePath
        self.meeting = meeting
    }

    /// Review state. An unknown raw value reads as `.accepted` so a to-do never
    /// disappears from the list because of a bad value.
    var status: TodoStatus {
        get { TodoStatus(rawValue: statusRaw) ?? .accepted }
        set { statusRaw = newValue.rawValue }
    }

    /// Quote verification; `nil` when not set or the raw value is unknown.
    var verification: VerificationState? {
        get { verificationRaw.flatMap(VerificationState.init(rawValue:)) }
        set { verificationRaw = newValue?.rawValue }
    }
}

/// Review state of a to-do: proposed by extraction, accepted, or rejected.
enum TodoStatus: String, Codable {
    case proposed, accepted, rejected
}
