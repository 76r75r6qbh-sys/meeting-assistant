// Casablanca/Views/ActionQueueView.swift
import SwiftUI

struct ActionQueueView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: ActionQueueFilter = .pending
    @State private var selectedItemID: String?

    private var model: ActionQueueModel { appModel.actionQueueModel }

    enum ActionQueueFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case pending = "Pending"
        case revising = "Revising"
        case approved = "Approved"
        case followUps = "Follow-ups"
        case awaiting = "Awaiting"
        case deferred = "Deferred"
        case done = "Done"

        var id: String { rawValue }

        func matches(_ status: ActionItemStatus) -> Bool {
            switch self {
            case .all: return true
            case .pending: return status == .pending
            case .revising: return status == .revisionRequested
            case .approved: return status == .approved
            case .followUps: return status == .followUp
            case .awaiting: return status == .awaitingContext
            case .deferred: return status == .deferred
            case .done: return status == .completed || status == .declined
            }
        }
    }

    var body: some View {
        // Read items in this view's tracked context so the body re-renders when
        // the watcher/bootstrap mutates the queue (same rule as the sidebar badge).
        let items = model.items
        let filtered = items.filter { filter.matches($0.status) }

        return content(filtered)
            .frame(maxWidth: CasaLayout.contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Approvals")
            .task {
                model.reload()
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $filter) {
                        ForEach(ActionQueueFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }
            }
            .sheet(item: selectedItemBinding) { item in
                ActionQueueDetailSheet(item: item, model: model) {
                    selectedItemID = nil
                }
            }
    }

    @ViewBuilder
    private func content(_ filtered: [ActionQueueItem]) -> some View {
        if filtered.isEmpty {
            VStack {
                emptyState
                Spacer(minLength: 0)
            }
        } else {
            List(filtered) { item in
                ActionQueueRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedItemID = item.id }
                    .contextMenu { contextMenu(for: item) }
            }
            .listStyle(.inset)
            .animation(reduceMotion ? nil : CasaAnimation.fast, value: filtered.map(\.id))
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ActionQueueItem) -> some View {
        switch item.status {
        case .pending, .revisionRequested:
            if item.kind == .draft {
                Button("Approve") { model.approve(id: item.id) }
                Button("Decline") { model.decline(id: item.id) }
            } else {
                Button("Mark Done") { model.complete(id: item.id) }
            }
            Button("Defer") { model.postpone(id: item.id) }
        case .approved, .declined, .completed, .deferred, .followUp, .awaitingContext, .unknown:
            if item.kind == .task, item.status != .completed {
                Button("Mark Done") { model.complete(id: item.id) }
            }
            Button("Reopen") { model.reopen(id: item.id) }
        }
    }

    private var selectedItemBinding: Binding<ActionQueueItem?> {
        Binding(
            get: { model.items.first { $0.id == selectedItemID } },
            set: { newValue in selectedItemID = newValue?.id }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return "Nothing Here"
        case .pending: return "All Caught Up"
        case .revising: return "Nothing Being Revised"
        case .approved: return "Nothing Approved"
        case .followUps: return "No Follow-ups"
        case .awaiting: return "Nothing Awaiting"
        case .deferred: return "Nothing Deferred"
        case .done: return "Nothing Done Yet"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .pending: return "checkmark.circle"
        case .done: return "tray"
        default: return "tray"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .all: return "Drafts and tracked actions from your Claude copilot will appear here."
        case .pending: return "Nothing waiting on you. 🎉"
        case .revising: return "Drafts you sent back for changes will appear here while the copilot re-drafts them."
        case .approved: return "Approved items awaiting execution by Claude will appear here."
        case .followUps: return "Tracked follow-ups for this week will appear here."
        case .awaiting: return "Items blocked on external input will appear here."
        case .deferred: return "Postponed items will appear here."
        case .done: return "Completed and declined items will appear here."
        }
    }
}

// MARK: - Row

private struct ActionQueueRow: View {
    let item: ActionQueueItem

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(item.title.isEmpty ? "(untitled)" : item.title)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if let target = item.target, !target.isEmpty {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let draftType = item.draftType {
                tag(draftType.rawValue.capitalized, color: Color.accentSecondary)
            }
            statusChip
        }
        .padding(.vertical, CasaSpace.xxs)
    }

    private var priorityColor: Color {
        switch item.priority {
        case .high: return Color.accentDanger
        case .medium: return Color.accentWarning
        case .low: return Color.textTertiary
        case .unknown: return Color.textTertiary
        }
    }

    private var statusChip: some View {
        tag(ActionQueuePresentation.statusLabel(item.status), color: ActionQueuePresentation.statusColor(item.status))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, CasaSpace.sm)
            .padding(.vertical, CasaSpace.xxs)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
    }
}

// MARK: - Presentation helpers

enum ActionQueuePresentation {
    static func statusLabel(_ status: ActionItemStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .declined: return "Declined"
        case .revisionRequested: return "Revising"
        case .followUp: return "Follow-up"
        case .awaitingContext: return "Awaiting"
        case .deferred: return "Deferred"
        case .completed: return "Done"
        case .unknown: return "Unknown"
        }
    }

    static func statusColor(_ status: ActionItemStatus) -> Color {
        switch status {
        case .pending: return Color.accentWarning
        case .approved: return Color.accentPrimary
        case .declined: return Color.accentDanger
        case .revisionRequested: return Color.accentSecondary
        case .followUp: return Color.accentSecondary
        case .awaitingContext: return Color.textSecondary
        case .deferred: return Color.textTertiary
        case .completed: return Color.accentSuccess
        case .unknown: return Color.textTertiary
        }
    }
}

// MARK: - Detail sheet

private struct ActionQueueDetailSheet: View {
    let item: ActionQueueItem
    let model: ActionQueueModel
    let onDismiss: () -> Void

    @State private var editedBody: String
    @State private var declineNote: String = ""
    @State private var revisionPrompt: String = ""
    @State private var showRevisionComposer = false

    init(item: ActionQueueItem, model: ActionQueueModel, onDismiss: @escaping () -> Void) {
        self.item = item
        self.model = model
        self.onDismiss = onDismiss
        _editedBody = State(initialValue: item.body)
    }

    private var isDraft: Bool { item.kind == .draft }
    /// Pending and revision-requested drafts are still actionable (approve / decline / steer).
    private var isDecidable: Bool { item.status == .pending || item.status == .revisionRequested }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CasaSpace.lg) {
                    header

                    // Origin — where this came from (e.g. the received email / Jira mention).
                    if let source = item.source, !source.isEmpty {
                        originBlock(source)
                    }

                    // Proposed reply — the editable draft Youri approves/declines.
                    if isDraft {
                        VStack(alignment: .leading, spacing: CasaSpace.xs) {
                            HStack(spacing: CasaSpace.xs) {
                                Image(systemName: "pencil.line")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentSecondary)
                                Text(draftLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.textSecondary)
                                Text("· editable")
                                    .font(.caption)
                                    .foregroundStyle(Color.textTertiary)
                            }
                            if editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No draft text yet — type a reply or ask your copilot to prepare one.")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentWarning)
                            }
                            TextEditor(text: $editedBody)
                                .font(.system(.body))
                                .frame(minHeight: 220)
                                .scrollContentBackground(.hidden)
                                .padding(CasaSpace.sm)
                                .background(
                                    RoundedRectangle(cornerRadius: CasaRadius.md)
                                        .fill(Color.accentSecondary.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: CasaRadius.md)
                                        .stroke(Color.textTertiary.opacity(0.3))
                                )
                        }
                    }

                    // A steer already sent back to the copilot (item is being re-drafted).
                    if item.status == .revisionRequested, let steer = item.revisionPrompt, !steer.isEmpty {
                        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                            Label("Sent back for changes — copilot is re-drafting", systemImage: "arrow.uturn.left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentSecondary)
                            Text(steer)
                                .font(.body)
                                .foregroundStyle(Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(CasaSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: CasaRadius.md)
                                .fill(Color.accentSecondary.opacity(0.08))
                        )
                    }

                    // Context — why this is here and where it's going.
                    if let rationale = item.rationale, !rationale.isEmpty {
                        labeledBlock("Why", rationale)
                    }
                    if let proposed = item.proposedAction, !proposed.isEmpty {
                        labeledBlock("Proposed action", proposed)
                    }

                    if let note = item.decisionNote, !note.isEmpty {
                        labeledBlock("Decision note", note)
                    }
                    if let result = item.executionResult, !result.isEmpty {
                        labeledBlock("Execution result", result)
                    }
                }
                .padding(.horizontal, CasaSpace.xl)
                .padding(.top, CasaSpace.lg)
                .padding(.bottom, CasaSpace.md)
            }

            Divider()
            actionBar
        }
        .frame(width: CasaLayout.modalWidthXL)
        .frame(minHeight: 420)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    /// Standard macOS close affordance in the top corner. Sized to Apple's
    /// circular close button (30×30 control, ~22pt glyph) with a 16pt inset from
    /// the edges (HIG panel margin / DESIGN_SYSTEM CasaSpace.lg). Non-destructive:
    /// just dismisses the sheet (Escape also works via the cancel-action shortcut).
    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .padding(CasaSpace.lg)
        .help("Close")
        .accessibilityLabel("Close")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            Text(item.title.isEmpty ? "(untitled)" : item.title)
                .font(.title3.weight(.semibold))
                .padding(.trailing, CasaSpace.xxl) // keep the title clear of the close button
            HStack(spacing: CasaSpace.sm) {
                Text(ActionQueuePresentation.statusLabel(item.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ActionQueuePresentation.statusColor(item.status))
                if let draftType = item.draftType {
                    Text("· \(draftType.rawValue.capitalized)")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
                Text("· \(item.priority.rawValue.capitalized) priority")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            if let target = item.target, !target.isEmpty {
                Label(target, systemImage: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    /// Popover composer revealed by the "Request changes…" button — kept out of
    /// the sheet by default so the draft stays the focus.
    private var revisionComposer: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Request a change")
                .font(.headline)
            Text("Tell your copilot how to re-draft this. It goes back to the queue and returns as a new pending draft.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "e.g. \u{201C}propose a call instead\u{201D}, \u{201C}more formal\u{201D}, \u{201C}push back on the deadline\u{201D}",
                text: $revisionPrompt,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(3...6)
            .padding(CasaSpace.sm)
            .overlay(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .stroke(Color.textTertiary.opacity(0.3))
            )

            HStack(spacing: CasaSpace.sm) {
                Spacer()
                Button("Cancel") { showRevisionComposer = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Send back") {
                    model.requestRevision(id: item.id, prompt: revisionPrompt)
                    showRevisionComposer = false
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(revisionPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(CasaSpace.lg)
        .frame(width: 360)
    }

    private var draftLabel: String {
        switch item.draftType {
        case .jira: return "Proposed comment"
        case .teams: return "Proposed message"
        case .email, .other, .unknown, .none: return "Proposed reply"
        }
    }

    private func labeledBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            Text(value)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func originBlock(_ source: String) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
            Label("Origin", systemImage: "tray.and.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            Text(source)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CasaRadius.md)
                .fill(Color.textTertiary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: CasaSpace.sm) {
            switch item.status {
            case .pending, .revisionRequested:
                if isDraft {
                    Button("Decline") {
                        model.decline(id: item.id, note: declineNote.isEmpty ? nil : declineNote)
                        onDismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Request changes…") {
                        showRevisionComposer = true
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showRevisionComposer, arrowEdge: .top) {
                        revisionComposer
                    }

                    Button("Approve") {
                        let trimmed = editedBody == item.body ? nil : editedBody
                        model.approve(id: item.id, editedBody: trimmed)
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()

                    Button("Mark Done") {
                        model.complete(id: item.id)
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            default:
                if item.kind == .task, item.status != .completed {
                    Button("Mark Done") {
                        model.complete(id: item.id)
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Reopen") {
                    model.reopen(id: item.id)
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, CasaSpace.xl)
        .padding(.vertical, CasaSpace.md)
    }
}
