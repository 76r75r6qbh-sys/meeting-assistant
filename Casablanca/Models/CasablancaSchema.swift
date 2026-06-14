import Foundation
import SwiftData

/// Explicit, versioned SwiftData schema history for Casablanca (DETERMINISTIC
/// HARDENING, not a reproduced fix).
///
/// Background: v0.8.0 silently reset some users' meeting stores during the
/// upgrade. The schema delta is known — `Meeting` dropped
/// `timestampedNotes: [TimestampedNote]` and added `tags: [String] = []` and
/// `localPrepNotes: String = ""` — but the destructive wipe is NOT reproducible
/// on every OS (a clean v0.7.1→current migration preserves rows on macOS 26).
/// SwiftData's INFERRED migration varies by OS version, and at least one real
/// store lost data under it.
///
/// This migration plan removes the inference: it declares the exact schema
/// versions and an explicit lightweight stage between them, so the upgrade path
/// is the same on every macOS version. The unconditional pre-open store backup
/// in ``PersistenceController`` remains THE guarantee against data loss; this
/// plan is deterministic hardening layered on top.
///
/// Note: the V1 models below are NESTED classes but still map to the SwiftData
/// entity names "Meeting" / "TodoItem" (SwiftData keys entities by the class's
/// simple name, not its enclosing scope), so they describe the same store the
/// v0.7.1 build wrote.

// MARK: - V1 (v0.7.1 schema)

/// The schema as shipped through v0.7.1: `Meeting` still has
/// `timestampedNotes`, and has NEITHER `tags` NOR `localPrepNotes`. Field set is
/// taken verbatim from `git show v0.7.1:Casablanca/Models/Meeting.swift` and
/// `...TodoItem.swift`.
enum CasablancaSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Meeting.self, TodoItem.self]
    }

    /// v0.7.1 `TimestampedNote` Codable struct — present in V1 only; the current
    /// schema dropped it.
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
            self.transcriptionLanguage = "en-US"
            self.createdAt = Date()
            self.todos = []
        }
    }

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
}

// MARK: - V2 (current schema)

/// The current schema: the top-level ``Meeting`` / ``TodoItem`` models are the
/// single source of truth. `Meeting` here has `tags` and `localPrepNotes` and no
/// longer has `timestampedNotes`.
enum CasablancaSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Meeting.self, TodoItem.self]
    }
}

// MARK: - Migration plan

/// Deterministic V1 → V2 migration. The delta is additive plus one dropped
/// property, so a lightweight (inferred-mapping) stage suffices — but declaring
/// it EXPLICITLY pins the path so it no longer depends on SwiftData's per-OS
/// inference.
enum CasablancaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [CasablancaSchemaV1.self, CasablancaSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: CasablancaSchemaV1.self, toVersion: CasablancaSchemaV2.self)]
    }
}
