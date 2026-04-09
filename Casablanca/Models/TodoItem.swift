// Casablanca/Models/TodoItem.swift
import Foundation
import SwiftData

@Model
final class TodoItem {
    var id: UUID
    var text: String
    var isCompleted: Bool
    var createdAt: Date
    var meeting: Meeting?

    init(text: String, meeting: Meeting? = nil) {
        self.id = UUID()
        self.text = text
        self.isCompleted = false
        self.createdAt = Date()
        self.meeting = meeting
    }
}
