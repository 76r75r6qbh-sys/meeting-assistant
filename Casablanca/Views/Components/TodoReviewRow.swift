// Casablanca/Views/Components/TodoReviewRow.swift
import SwiftData
import SwiftUI

/// What a to-do under review shows: its verification badge, the caption line
/// (`owner · due · [mm:ss]`) and its quote. Pure, so it is unit-testable.
struct TodoReviewPresentation {
    /// The quote verification verdict as a badge.
    enum Badge: Equatable {
        /// `.supported`: the quote was found in the transcript.
        case verified
        /// `.unsupported`, with the verifier's reason when the meeting's
        /// extracted item still carries it.
        case unsupported(reason: String?)
        /// `.unverified`, or never checked (`nil`, legacy to-dos).
        case unverified

        init(_ verification: VerificationState?, reason: String?) {
            switch verification {
            case .supported: self = .verified
            case .unsupported: self = .unsupported(reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank)
            case .unverified, nil: self = .unverified
            }
        }

        var symbolName: String {
            switch self {
            case .verified: return "checkmark.seal.fill"
            case .unsupported: return "exclamationmark.triangle.fill"
            case .unverified: return "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .verified: return Color.accentSuccess
            case .unsupported: return Color.accentWarning
            case .unverified: return Color.textTertiary
            }
        }

        var help: String {
            switch self {
            case .verified: return "Supported by the transcript"
            case .unsupported(let reason): return reason ?? "Not supported by the transcript"
            case .unverified: return "Not checked"
            }
        }
    }

    let badge: Badge
    let ownerText: String?
    /// The due date as `vr 6 nov` (`EEE d MMM`, current locale).
    let dueText: String?
    /// `[mm:ss]` of the quote.
    let timestampLabel: String?
    /// The quote in typographic quotes.
    let quoteText: String?

    /// `actionItems` are the meeting's decoded extracted items, the source of
    /// an unsupported verdict's reason; callers decode them once per meeting,
    /// not per row. Without them the badge has no reason.
    init(todo: TodoItem, actionItems: [ExtractedActionItem] = []) {
        badge = Badge(todo.verification, reason: Self.verificationReason(for: todo, in: actionItems))
        ownerText = todo.owner?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        dueText = todo.dueDate.map(Self.dueText)
        timestampLabel = todo.sourceTimestamp?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { "[\($0)]" }
        quoteText = todo.quote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { "\u{201C}\($0)\u{201D}" }
    }

    /// `owner · due`, each only when set; `nil` when neither is.
    var ownerAndDueText: String? {
        let parts = [ownerText, dueText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Whether the caption line has anything to show.
    var hasCaption: Bool { ownerAndDueText != nil || timestampLabel != nil }

    /// Current locale, like the app's other date captions.
    private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    static func dueText(_ date: Date) -> String {
        dueFormatter.string(from: date)
    }

    /// How many to-dos "Accept all verified" accepts: proposed and supported.
    static func acceptAllVerifiedCount(_ todos: [TodoItem]) -> Int {
        todos.filter { $0.status == .proposed && $0.verification == .supported }.count
    }

    /// The meeting's proposed to-dos in review order (oldest first).
    static func proposedTodos(of meeting: Meeting) -> [TodoItem] {
        sortedForReview(meeting.todos.filter { $0.status == .proposed })
    }

    static func sortedForReview(_ todos: [TodoItem]) -> [TodoItem] {
        todos.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// The verifier's reason, from the meeting's extracted item with the same
    /// task or (after an edit) the same quote and timestamp — the lookup the
    /// decision log uses. TodoItem itself has no reason field.
    private static func verificationReason(for todo: TodoItem, in items: [ExtractedActionItem]) -> String? {
        guard todo.verification == .unsupported, !items.isEmpty else { return nil }
        let source = items.first { $0.task.trimmingCharacters(in: .whitespacesAndNewlines) == todo.text }
            ?? items.first { todo.quote != nil && $0.quote == todo.quote && $0.timestamp == todo.sourceTimestamp }
        return source?.verificationReason
    }

    // MARK: - Summary tab bullets

    /// The action-items header suffix: `· X of N done`, where N counts only
    /// bullets with a completion toggle (proposed and read-only bullets can't
    /// be done); `nil` when there are none.
    static func doneSummary(_ states: [SummaryBulletState]) -> String? {
        var total = 0
        var done = 0
        for case .toggle(let todo) in states {
            total += 1
            if todo?.isCompleted == true { done += 1 }
        }
        return total == 0 ? nil : "\u{00B7} \(done) of \(total) done"
    }

    /// How the summary tab shows one action-item bullet.
    enum SummaryBulletState {
        /// The completion toggle (an accepted to-do, or none yet in a legacy
        /// meeting, where checking creates one).
        case toggle(TodoItem?)
        /// A proposed to-do: the review state, no toggle; the strip reviews it.
        case review(TodoItem)
        /// Another person's (or an unassigned, or a rejected) item in a
        /// meeting with structured items: owner and badge, read-only.
        case readOnly(owner: String?, action: String, badge: Badge)
    }

    /// The bullet's state from the matching to-do (`ActionItemTodoMatcher`)
    /// and, in meetings with structured items, the item it was rendered from.
    static func summaryBulletState(
        for bullet: String,
        todos: [TodoItem],
        items: [ExtractedActionItem]
    ) -> SummaryBulletState {
        if let match = ActionItemTodoMatcher.matchingTodo(for: bullet, in: todos) {
            return match.status == .proposed ? .review(match) : .toggle(match)
        }
        guard !items.isEmpty else { return .toggle(nil) }
        let target = bullet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = items.first(where: { ActionItemRendering.bullet(for: $0) == target }) else {
            // Not one of the structured bullets (an older summary text):
            // behave like a legacy meeting.
            return .toggle(nil)
        }
        let action = ActionItemRendering.strippingSuffix(ActionItemOwnership.parse(target).action)
        return .readOnly(
            owner: item.owner?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            action: action.isEmpty ? target : action,
            badge: Badge(item.verified, reason: item.verificationReason)
        )
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}

/// The verification badge as a small symbol with its explanation as help.
struct TodoVerificationBadge: View {
    let badge: TodoReviewPresentation.Badge

    var body: some View {
        Image(systemName: badge.symbolName)
            .font(.caption)
            .foregroundStyle(badge.color)
            .help(badge.help)
            .accessibilityLabel(badge.help)
    }
}

/// One proposed to-do under review: task, caption (`owner · due · [mm:ss]`),
/// quote, and Accept / Edit / Reject.
struct TodoReviewRow: View {
    let todo: TodoItem
    /// The meeting's decoded extracted items (for the badge's reason).
    var actionItems: [ExtractedActionItem] = []
    let onAccept: () -> Void
    let onReject: () -> Void
    let onEdit: (String, String?, Date?) -> Void

    @State private var isEditing = false

    var body: some View {
        let presentation = TodoReviewPresentation(todo: todo, actionItems: actionItems)
        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: CasaSpace.xs) {
                TodoVerificationBadge(badge: presentation.badge)
                Text(todo.text)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if presentation.hasCaption {
                HStack(spacing: 0) {
                    if let ownerAndDue = presentation.ownerAndDueText {
                        Text(ownerAndDue)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if presentation.timestampLabel != nil {
                            Text(" \u{00B7} ")
                        }
                    }
                    if let label = presentation.timestampLabel {
                        timestampText(label)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
            }

            if let quote = presentation.quoteText {
                Text(quote)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(spacing: CasaSpace.sm) {
                Button("Accept", action: onAccept)
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Accept this to-do")
                Button("Edit") { isEditing = true }
                    .buttonStyle(GhostButtonStyle())
                    .help("Edit the task, owner or due date")
                    .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                        TodoReviewEditForm(
                            task: todo.text,
                            owner: todo.owner ?? "",
                            dueDate: todo.dueDate,
                            participants: todo.meeting?.participants ?? []
                        ) { task, owner, due in
                            isEditing = false
                            onEdit(task, owner, due)
                        }
                    }
                Button("Reject", action: onReject)
                    .buttonStyle(GhostButtonStyle())
                    .help("Reject this to-do")
            }
            .padding(.top, CasaSpace.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The quote's transcript timestamp — the one place it is drawn — as a
    /// link that jumps to that moment of the to-do's meeting (plain text
    /// when the to-do has no meeting).
    func timestampText(_ label: String) -> Text {
        TimestampLinkText.text(label, meetingID: todo.meeting?.id).monospacedDigit()
    }
}

/// The Edit popover: task, owner (with the meeting's participants as
/// suggestions) and an optional due date.
private struct TodoReviewEditForm: View {
    @State private var task: String
    @State private var owner: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    let participants: [String]
    let onSave: (String, String?, Date?) -> Void

    init(task: String, owner: String, dueDate: Date?, participants: [String], onSave: @escaping (String, String?, Date?) -> Void) {
        _task = State(initialValue: task)
        _owner = State(initialValue: owner)
        _hasDueDate = State(initialValue: dueDate != nil)
        _dueDate = State(initialValue: dueDate ?? Calendar.current.startOfDay(for: Date()))
        self.participants = participants
        self.onSave = onSave
    }

    private var suggestions: [String] {
        var seen = Set<String>()
        return participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            TextField("Task", text: $task, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: CasaSpace.xs) {
                TextField("Owner", text: $owner)
                    .textFieldStyle(.roundedBorder)
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) { owner = name }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick a participant")
                    .accessibilityLabel("Pick a participant")
                }
            }
            Toggle("Due date", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Save") {
                    onSave(task, owner, hasDueDate ? dueDate : nil)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(CasaSpace.lg)
        .frame(width: CasaLayout.popoverWidth)
    }
}
