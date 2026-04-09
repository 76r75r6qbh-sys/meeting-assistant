// Casablanca/Models/PendingTodoReview.swift
import Foundation

struct PendingTodoReview: Identifiable {
    let id = UUID()
    let meetingID: UUID
    let summary: String
    var todoTexts: [String]
}
