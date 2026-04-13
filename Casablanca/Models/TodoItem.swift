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
}
