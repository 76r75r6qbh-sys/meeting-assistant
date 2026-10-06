import Foundation

// MARK: - Enums

// DATA PRESERVATION: the action-queue JSON is co-written by an external Claude
// Code agent. If the agent introduces a new enum value (e.g. a new status), a
// strict decode would either throw or — worse, since save rewrites the WHOLE
// document — silently rewrite the value to a known fallback and PERMANENTLY
// lose the agent's intent. To avoid that, every String-raw enum below carries a
// `case unknown(String)` that preserves the original raw string verbatim and
// re-emits it unchanged on the next save (lossless round-trip).

/// Whether an item has an approvable draft body or is tracking-only.
enum ActionItemKind: Codable, Hashable, CaseIterable {
    case draft
    case task
    /// An unrecognized value from the agent's file; the associated string is
    /// preserved verbatim for lossless round-tripping.
    case unknown(String)

    static let allCases: [ActionItemKind] = [.draft, .task]

    var rawValue: String {
        switch self {
        case .draft: return "draft"
        case .task: return "task"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "draft": self = .draft
        case "task": self = .task
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The destination type for a draft.
enum ActionDraftType: Codable, Hashable, CaseIterable {
    case email
    case jira
    case teams
    case calendar
    case topdesk
    case other
    /// An unrecognized value from the agent's file; preserved verbatim.
    case unknown(String)

    static let allCases: [ActionDraftType] = [.email, .jira, .teams, .calendar, .topdesk, .other]

    var rawValue: String {
        switch self {
        case .email: return "email"
        case .jira: return "jira"
        case .teams: return "teams"
        case .calendar: return "calendar"
        case .topdesk: return "topdesk"
        case .other: return "other"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "email": self = .email
        case "jira": self = .jira
        case "teams": self = .teams
        case "calendar": self = .calendar
        case "topdesk": self = .topdesk
        case "other": self = .other
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Relative importance of an item.
enum ActionItemPriority: Codable, Hashable, CaseIterable {
    case low
    case medium
    case high
    /// An unrecognized value from the agent's file; preserved verbatim.
    case unknown(String)

    static let allCases: [ActionItemPriority] = [.low, .medium, .high]

    var rawValue: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Sort weight: high first, unknown last.
    var sortRank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        case .unknown: return 3
        }
    }
}

/// Lifecycle state of an item. RawValues match the JSON contract.
enum ActionItemStatus: Codable, Hashable, CaseIterable {
    case pending
    case approved
    case declined
    case revisionRequested
    case followUp
    case awaitingContext
    case deferred
    case completed
    /// An unrecognized value from the agent's file; preserved verbatim.
    case unknown(String)

    static let allCases: [ActionItemStatus] = [
        .pending, .approved, .declined, .revisionRequested,
        .followUp, .awaitingContext, .deferred, .completed,
    ]

    var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .approved: return "approved"
        case .declined: return "declined"
        case .revisionRequested: return "revision_requested"
        case .followUp: return "follow_up"
        case .awaitingContext: return "awaiting_context"
        case .deferred: return "deferred"
        case .completed: return "completed"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "approved": self = .approved
        case "declined": self = .declined
        case "revision_requested": self = .revisionRequested
        case "follow_up": self = .followUp
        case "awaiting_context": self = .awaitingContext
        case "deferred": self = .deferred
        case "completed": self = .completed
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Workflow bucket an item belongs to. A missing bucket means "General".
/// RawValues match the JSON contract.
enum ActionBucket: Codable, Hashable, CaseIterable {
    case partnerApiReply
    case ticketDraft
    case topdeskResponse
    case refinementPrep
    case calendarEvent
    case roadmapCommitment
    case todo
    /// An unrecognized value from the agent's file; preserved verbatim.
    case unknown(String)

    // Declaration order is the fixed display order and matches `sortOrder`.
    static let allCases: [ActionBucket] = [
        .partnerApiReply, .ticketDraft, .topdeskResponse, .refinementPrep,
        .calendarEvent, .roadmapCommitment, .todo,
    ]

    var rawValue: String {
        switch self {
        case .partnerApiReply: return "partner_api_reply"
        case .ticketDraft: return "ticket_draft"
        case .topdeskResponse: return "topdesk_response"
        case .refinementPrep: return "refinement_prep"
        case .roadmapCommitment: return "roadmap_commitment"
        case .calendarEvent: return "calendar_event"
        case .todo: return "todo"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "partner_api_reply": self = .partnerApiReply
        case "ticket_draft": self = .ticketDraft
        case "topdesk_response": self = .topdeskResponse
        case "refinement_prep": self = .refinementPrep
        case "roadmap_commitment": self = .roadmapCommitment
        case "calendar_event": self = .calendarEvent
        case "todo": self = .todo
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Human-readable label for display.
    var displayName: String {
        switch self {
        case .partnerApiReply: return "Partner API reply"
        case .ticketDraft: return "Ticket draft"
        case .topdeskResponse: return "Topdesk response"
        case .refinementPrep: return "Refinement prep"
        case .roadmapCommitment: return "Roadmap commitment"
        case .calendarEvent: return "Calendar event"
        case .todo: return "To-do"
        case .unknown(let raw): return raw
        }
    }

    /// Fixed display order; unknown buckets sort last.
    var sortOrder: Int {
        switch self {
        case .partnerApiReply: return 0
        case .ticketDraft: return 1
        case .topdeskResponse: return 2
        case .refinementPrep: return 3
        case .calendarEvent: return 4
        case .roadmapCommitment: return 5
        case .todo: return 6
        case .unknown: return 7
        }
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
    /// Workflow bucket grouping. Missing => nil ("General"); unrecognized value
    /// decodes to `.unknown(_)` and round-trips verbatim.
    var bucket: ActionBucket?
    /// Paths/identifiers of attachments associated with this item.
    var attachments: [String]?
    /// An opaque external reference (e.g. `forta:x`) tying the item to an
    /// upstream system.
    var externalRef: String?
    /// IDs of other action-queue items this one is linked to.
    var linkedItemIds: [String]?
    /// Keys present in the agent's JSON that this build's schema doesn't model.
    /// Preserved verbatim and re-emitted on save so the whole-document rewrite
    /// never silently drops fields the agent added (forward-compatibility).
    var extraKeys: [String: JSONValue]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, draftType, title, priority, target, source, rationale
        case body, proposedAction, status, decisionNote, revisionPrompt, createdAt
        case decidedAt, executedAt, executionResult
        case bucket, attachments, externalRef, linkedItemIds
    }

    /// Dynamic key used to read/write keys outside the fixed schema.
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let knownKeys: Set<String> = Set(CodingKeys.allCases.map { $0.stringValue })

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
        executionResult: String? = nil,
        bucket: ActionBucket? = nil,
        attachments: [String]? = nil,
        externalRef: String? = nil,
        linkedItemIds: [String]? = nil,
        extraKeys: [String: JSONValue] = [:]
    ) {
        self.extraKeys = extraKeys
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
        self.bucket = bucket
        self.attachments = attachments
        self.externalRef = externalRef
        self.linkedItemIds = linkedItemIds
    }

    /// `true` when any enum field fell back to `unknown(_)` during decode — the
    /// agent wrote a value this build doesn't recognize. Drives the non-fatal
    /// load warning without losing the raw string (it round-trips on save).
    var hasUnknownEnumValue: Bool {
        if case .unknown = kind { return true }
        if case .unknown = priority { return true }
        if case .unknown = status { return true }
        if case .unknown? = draftType { return true }
        if case .unknown? = bucket { return true }
        return false
    }

    /// Attempt to build a typed item from a captured raw JSON element. Re-encodes
    /// the raw value and decodes it through the date-aware decoder so the normal
    /// (lenient) `init(from:)` runs. Throws if the element is structurally broken
    /// (e.g. missing `id`), in which case the caller retains it verbatim.
    init(fromLenient raw: JSONValue) throws {
        let data = try ActionQueueItem.passthroughEncoder.encode(raw)
        self = try ActionQueueItem.passthroughDecoder.decode(ActionQueueItem.self, from: data)
    }

    private static let passthroughEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // JSONValue carries no Date values, so the date strategy is irrelevant
        // here; keys/values are preserved as-is for the re-decode below.
        return encoder
    }()

    private static let passthroughDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        ActionQueueDateFormat.configureDecoder(decoder)
        return decoder
    }()

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
        bucket = try c.decodeIfPresent(ActionBucket.self, forKey: .bucket)
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments)
        externalRef = try c.decodeIfPresent(String.self, forKey: .externalRef)
        linkedItemIds = try c.decodeIfPresent([String].self, forKey: .linkedItemIds)

        // Capture any keys outside the fixed schema so the rewrite preserves them.
        var extras: [String: JSONValue] = [:]
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        extraKeys = extras
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(draftType, forKey: .draftType)
        try c.encode(title, forKey: .title)
        try c.encode(priority, forKey: .priority)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(rationale, forKey: .rationale)
        try c.encode(body, forKey: .body)
        try c.encodeIfPresent(proposedAction, forKey: .proposedAction)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(decisionNote, forKey: .decisionNote)
        try c.encodeIfPresent(revisionPrompt, forKey: .revisionPrompt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(decidedAt, forKey: .decidedAt)
        try c.encodeIfPresent(executedAt, forKey: .executedAt)
        try c.encodeIfPresent(executionResult, forKey: .executionResult)
        try c.encodeIfPresent(bucket, forKey: .bucket)
        try c.encodeIfPresent(attachments, forKey: .attachments)
        try c.encodeIfPresent(externalRef, forKey: .externalRef)
        try c.encodeIfPresent(linkedItemIds, forKey: .linkedItemIds)

        // Re-emit preserved unknown keys verbatim.
        if !extraKeys.isEmpty {
            var dynamic = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in extraKeys {
                guard let codingKey = DynamicKey(stringValue: key) else { continue }
                try dynamic.encode(value, forKey: codingKey)
            }
        }
    }
}

// MARK: - Raw JSON passthrough

/// A loss-free, decode-anything / re-encode-verbatim JSON value. Used to retain
/// items the typed model cannot decode so the whole-document rewrite never drops
/// the agent's data. Decoding is intentionally tolerant; encoding re-emits the
/// exact structure that was decoded (subject to key ordering, which the encoder
/// sorts — values and keys themselves are preserved).
///
/// DATA PRESERVATION (numbers): JSON draws no int/float distinction, so a single
/// `.number(Decimal)` case backs every numeric literal. `Decimal` is decoded
/// directly from the JSON number token by Foundation's `JSONDecoder`, which
/// avoids the magnitude/precision loss of routing through `Int` (overflow) then
/// `Double` (lossy ~15–17 significant digits). An agent-supplied ID such as
/// `9999999999999999999` — larger than `Int64.max` — therefore round-trips with
/// its exact digits instead of corrupting to `1e+19`. The only normalization is
/// cosmetic: a whole-number literal written as `42.0` re-emits as `42`, which is
/// acceptable because JSON cannot distinguish the two (magnitude/precision are
/// preserved; only the redundant `.0` is dropped).
indirect enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            // Decimal captures the full numeric token (incl. integers > Int64.max)
            // without the precision loss of an Int-then-Double fallback chain.
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Document

struct ActionQueueDocument: Codable {
    var version: Int
    var updatedAt: Date?
    var items: [ActionQueueItem]
    /// Items that failed to decode as `ActionQueueItem` but are retained verbatim
    /// so the whole-document rewrite never deletes the agent's data. These are
    /// NOT surfaced to the UI. Re-emitted unchanged on save, APPENDED after the
    /// typed items (original position within the array is not preserved — only
    /// the data is). In practice unparsable items are rare, so trailing them is
    /// an acceptable, data-preserving ordering choice.
    var unparsedItems: [JSONValue]
    /// `true` when at least one item could not be decoded or carried an unknown
    /// enum value. Drives a non-fatal warning in the UI.
    var hadLenientFallback: Bool
    /// Top-level keys outside the fixed schema, preserved verbatim and re-emitted
    /// on save so the rewrite never drops document-level fields the agent added.
    var extraKeys: [String: JSONValue]

    init(
        version: Int = 1,
        updatedAt: Date? = nil,
        items: [ActionQueueItem] = [],
        unparsedItems: [JSONValue] = [],
        hadLenientFallback: Bool = false,
        extraKeys: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.items = items
        self.unparsedItems = unparsedItems
        self.hadLenientFallback = hadLenientFallback
        self.extraKeys = extraKeys
    }

    /// Number of items that could not be parsed and were preserved verbatim.
    var unparsedItemCount: Int { unparsedItems.count }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, updatedAt, items
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let knownKeys: Set<String> = Set(CodingKeys.allCases.map { $0.stringValue })

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)

        // Decode the items array element-by-element through a tolerant wrapper:
        // a single structurally-broken item must not abort the whole load.
        var parsed: [ActionQueueItem] = []
        var unparsed: [JSONValue] = []
        var sawUnknownEnum = false

        if var arrayContainer = try? c.nestedUnkeyedContainer(forKey: .items) {
            while !arrayContainer.isAtEnd {
                // Capture the raw element first so we can re-emit it verbatim if
                // typed decoding fails. `superDecoder()` advances the container.
                let elementDecoder = try arrayContainer.superDecoder()
                let raw = try JSONValue(from: elementDecoder)
                if let item = try? ActionQueueItem(fromLenient: raw) {
                    parsed.append(item)
                    if item.hasUnknownEnumValue { sawUnknownEnum = true }
                } else {
                    unparsed.append(raw)
                }
            }
        }

        items = parsed
        unparsedItems = unparsed
        hadLenientFallback = sawUnknownEnum || !unparsed.isEmpty

        // Preserve any top-level keys outside the fixed schema.
        var extras: [String: JSONValue] = [:]
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        extraKeys = extras
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)

        // Re-emit typed items followed by the retained unparsed items verbatim.
        var arrayContainer = c.nestedUnkeyedContainer(forKey: .items)
        for item in items {
            try arrayContainer.encode(item)
        }
        for raw in unparsedItems {
            try arrayContainer.encode(raw)
        }

        // Re-emit preserved unknown top-level keys verbatim.
        if !extraKeys.isEmpty {
            var dynamic = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in extraKeys {
                guard let codingKey = DynamicKey(stringValue: key) else { continue }
                try dynamic.encode(value, forKey: codingKey)
            }
        }
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
