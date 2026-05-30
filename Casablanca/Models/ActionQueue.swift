import Foundation

// MARK: - Enums

/// Whether an item has an approvable draft body or is tracking-only.
enum ActionItemKind: String, Codable, Hashable, CaseIterable {
    case draft
    case task

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = ActionItemKind(rawValue: try container.decode(String.self)) ?? .task
    }
}

/// The destination type for a draft.
enum ActionDraftType: String, Codable, Hashable, CaseIterable {
    case email
    case jira
    case teams
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = ActionDraftType(rawValue: try container.decode(String.self)) ?? .other
    }
}

/// Relative importance of an item.
enum ActionItemPriority: String, Codable, Hashable, CaseIterable {
    case low
    case medium
    case high

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = ActionItemPriority(rawValue: try container.decode(String.self)) ?? .medium
    }

    /// Sort weight: high first.
    var sortRank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

/// Lifecycle state of an item. RawValues match the JSON contract.
enum ActionItemStatus: String, Codable, Hashable, CaseIterable {
    case pending
    case approved
    case declined
    case revisionRequested = "revision_requested"
    case followUp = "follow_up"
    case awaitingContext = "awaiting_context"
    case deferred
    case completed

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = ActionItemStatus(rawValue: try container.decode(String.self)) ?? .pending
    }
}

// MARK: - Item

struct ActionQueueItem: Codable, Identifiable, Hashable {
    var id: String
    var kind: ActionItemKind
    var draftType: ActionDraftType?
    var title: String
    var priority: ActionItemPriority
    var target: String?
    var source: String?
    var rationale: String?
    var body: String
    var proposedAction: String?
    var status: ActionItemStatus
    var decisionNote: String?
    /// Free-text steer from Youri asking the copilot to re-draft / change direction.
    /// Set when status is `revisionRequested`; cleared by the copilot after re-drafting.
    var revisionPrompt: String?
    var createdAt: Date?
    var decidedAt: Date?
    var executedAt: Date?
    var executionResult: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind, draftType, title, priority, target, source, rationale
        case body, proposedAction, status, decisionNote, revisionPrompt, createdAt
        case decidedAt, executedAt, executionResult
    }

    init(
        id: String,
        kind: ActionItemKind = .task,
        draftType: ActionDraftType? = nil,
        title: String = "",
        priority: ActionItemPriority = .medium,
        target: String? = nil,
        source: String? = nil,
        rationale: String? = nil,
        body: String = "",
        proposedAction: String? = nil,
        status: ActionItemStatus = .pending,
        decisionNote: String? = nil,
        revisionPrompt: String? = nil,
        createdAt: Date? = nil,
        decidedAt: Date? = nil,
        executedAt: Date? = nil,
        executionResult: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.draftType = draftType
        self.title = title
        self.priority = priority
        self.target = target
        self.source = source
        self.rationale = rationale
        self.body = body
        self.proposedAction = proposedAction
        self.status = status
        self.decisionNote = decisionNote
        self.revisionPrompt = revisionPrompt
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.executedAt = executedAt
        self.executionResult = executionResult
    }

    // Lenient decode: missing optional keys must not fail.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(ActionItemKind.self, forKey: .kind) ?? .task
        draftType = try c.decodeIfPresent(ActionDraftType.self, forKey: .draftType)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        priority = try c.decodeIfPresent(ActionItemPriority.self, forKey: .priority) ?? .medium
        target = try c.decodeIfPresent(String.self, forKey: .target)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        proposedAction = try c.decodeIfPresent(String.self, forKey: .proposedAction)
        status = try c.decodeIfPresent(ActionItemStatus.self, forKey: .status) ?? .pending
        decisionNote = try c.decodeIfPresent(String.self, forKey: .decisionNote)
        revisionPrompt = try c.decodeIfPresent(String.self, forKey: .revisionPrompt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        executedAt = try c.decodeIfPresent(Date.self, forKey: .executedAt)
        executionResult = try c.decodeIfPresent(String.self, forKey: .executionResult)
    }
}

// MARK: - Document

struct ActionQueueDocument: Codable {
    var version: Int
    var updatedAt: Date?
    var items: [ActionQueueItem]

    init(version: Int = 1, updatedAt: Date? = nil, items: [ActionQueueItem] = []) {
        self.version = version
        self.updatedAt = updatedAt
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        items = try c.decodeIfPresent([ActionQueueItem].self, forKey: .items) ?? []
    }
}

// MARK: - Date strategies

/// ISO-8601 date (de)serialization for the action queue. A single
/// `ISO8601DateFormatter` cannot parse both `...Z` and `...123Z`, so we try
/// the fractional-seconds formatter first, then the plain one. Encoding uses
/// the plain (no fractional seconds) form.
enum ActionQueueDateFormat {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    static func string(from date: Date) -> String {
        plain.string(from: date)
    }

    static func configureDecoder(_ decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ActionQueueDateFormat.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(raw)"
                )
            }
            return date
        }
    }

    static func configureEncoder(_ encoder: JSONEncoder) {
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ActionQueueDateFormat.string(from: date))
        }
    }
}
