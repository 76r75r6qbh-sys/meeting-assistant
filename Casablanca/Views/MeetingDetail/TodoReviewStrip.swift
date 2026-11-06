// Casablanca/Views/MeetingDetail/TodoReviewStrip.swift
import SwiftData
import SwiftUI

/// The review decisions every review surface (summary strip, Todos → Review,
/// meeting panel) runs: `TodoReviewService` against the view's context, an
/// automatic export after any accept (so Apple Notes / the summary file get
/// the accepted list), and failures as a toast.
@MainActor
struct TodoReviewActions {
    let modelContext: ModelContext
    let appModel: AppModel

    func accept(_ todo: TodoItem) {
        let meeting = todo.meeting
        let succeeded = perform("accept the to-do") {
            try TodoReviewService.accept(todo, in: modelContext)
        }
        if succeeded { exportAfterAccept(meeting) }
    }

    func reject(_ todo: TodoItem) {
        perform("reject the to-do") {
            try TodoReviewService.reject(todo, in: modelContext)
        }
    }

    func edit(_ todo: TodoItem, task: String, owner: String?, dueDate: Date?) {
        perform("save the edit") {
            try TodoReviewService.edit(todo, task: task, owner: owner, dueDate: dueDate, in: modelContext)
        }
    }

    func acceptAllVerified(in meeting: Meeting) {
        guard TodoReviewPresentation.acceptAllVerifiedCount(meeting.todos) > 0 else { return }
        perform("accept the verified to-dos") {
            try TodoReviewService.acceptAllVerified(in: meeting, in: modelContext)
        }
        // Also after a failure part-way: the earlier ones are accepted.
        exportAfterAccept(meeting)
    }

    @discardableResult
    private func perform(_ what: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            appModel.toastCenter.show(message: "Couldn't \(what) — \(error.localizedDescription)")
            return false
        }
    }

    private func exportAfterAccept(_ meeting: Meeting?) {
        guard let meeting else { return }
        let reporter = appModel.exportStatusCenter
        Task { @MainActor in
            await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: reporter)
        }
    }
}

/// Top of the summary tab (below the hero) while the meeting has proposed
/// to-dos: "Review to-dos (N)", "Accept all verified (K)" and one
/// `TodoReviewRow` per proposal.
struct TodoReviewStrip: View {
    @Bindable var meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let proposed = TodoReviewPresentation.proposedTodos(of: meeting)
        if !proposed.isEmpty {
            let actions = TodoReviewActions(modelContext: modelContext, appModel: appModel)
            TodoReviewStripContent(
                todos: proposed,
                verifiedCount: TodoReviewPresentation.acceptAllVerifiedCount(proposed),
                onAccept: actions.accept,
                onReject: actions.reject,
                onEdit: { todo, task, owner, due in actions.edit(todo, task: task, owner: owner, dueDate: due) },
                onAcceptAllVerified: { actions.acceptAllVerified(in: meeting) }
            )
        }
    }
}

/// The strip's layout, without environment, so it can be laid out in tests.
struct TodoReviewStripContent: View {
    let todos: [TodoItem]
    let verifiedCount: Int
    let onAccept: (TodoItem) -> Void
    let onReject: (TodoItem) -> Void
    let onEdit: (TodoItem, String, String?, Date?) -> Void
    let onAcceptAllVerified: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            // Side by side when there is room, stacked in a narrow column.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                    title
                    Spacer(minLength: CasaSpace.sm)
                    acceptAllButton
                }
                VStack(alignment: .leading, spacing: CasaSpace.sm) {
                    title
                    acceptAllButton
                }
            }

            ForEach(todos) { todo in
                if todo.id != todos.first?.id {
                    Divider()
                }
                TodoReviewRow(
                    todo: todo,
                    onAccept: { onAccept(todo) },
                    onReject: { onReject(todo) },
                    onEdit: { task, owner, due in onEdit(todo, task, owner, due) }
                )
            }
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.textTertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: CasaRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.lg)
                .strokeBorder(Color.textTertiary.opacity(0.25), lineWidth: 1)
        )
    }

    private var title: some View {
        Label("Review to-dos (\(todos.count))", systemImage: "checklist")
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Color.textSecondary)
            .symbolRenderingMode(.hierarchical)
            // Never truncated: in a narrow column the header stacks instead.
            .fixedSize(horizontal: true, vertical: false)
    }

    private var acceptAllButton: some View {
        Button("Accept all verified (\(verifiedCount))", action: onAcceptAllVerified)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(verifiedCount == 0)
            .help("Accept every to-do whose quote is confirmed by the transcript")
    }
}
